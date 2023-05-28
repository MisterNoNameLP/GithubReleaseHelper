#!/usr/bin/pleal

--[[
	GithubReleaseHelper Copyright (c) 2023  MisterNoNameLP

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]

local version = "1.2"
local name = "GithubReleaseHelper"

--===== conf =====--
-- default configuration. args with the same meaning have higher priority.
local url = "" --repo URL/releases
local releaseFiles = {} --a list of individual files and fiolder to attach to the realease
local releaseFolders = {} --folder in wich files and folders are store to be release seperately
local tokenPath = "" --path to file containing the bearer token 
local tmpReleaseFileLocation = ".compressedReleaseFiles.zip" --relative to the releaseFolders if starting with a dot. its recommended to have this on a ramfs

--===== runtime vars =====--
local http = require("http.request")
local ut = require("UT")
local json = require("json")
local argparse = require("argparse")
local len = require("utf8").len
local lfs = require("lfs")

local args
local token = ut.readFile(tokenPath)
local uploadUrl
local uploadedFiles = {}

--===== init =====--
do --arg parsing 
	local parser = argparse(name)

	parser:option("-u --url --upstream", "The github upsream url"):action(function(_, _, arg) url = arg end)
	parser:option("-t --tag", "Release tag"):count(1):args(1):target("tag")
	parser:option("-n --name", "Relase name"):count(1):args(1):target("name")
	parser:option("-d --description", "Relase description"):count(1):args(1):target("description")
	parser:option("-T --target", "Target branch"):count(1):args(1):target("target")
	
	parser:flag("-D --draft", "Draft"):target("draft")
	parser:flag("-P --prerelease", "Prerelease"):target("prerelease")
	parser:flag("-G --generate-release-notes", "Generate release notes"):target("notes")

	parser:option("--token", "The path to a file containing the authentification token"):action(function(_, _, arg) 
		if lfs.attributes(arg) then
			token = ut.readFile(arg)
		else
			print("ERROR: Token not found")
			os.exit()
		end
	end)
	parser:option("-r --release-file", "Single folder/file to attach to the release"):count("*"):target("releaseFiles")
	parser:option("-R --release-folder", "Folder in wich release folder/files are stored and release seperately"):count("*"):target("releaseFolders")
	parser:option("--compression-path", "The path where compressed release folder are temporarly stored"):action(function(_, _, arg) tmpReleaseFileLocation = arg end)

	parser:option("--log-level", "Set the log level (0-4)"):default(0):target("logLevel")
	parser:flag("--dump-auth-token", "Does not censore the authentification token on log-level 2"):target("noAuthCensor")
	parser:flag("-v --version", "log version and exit"):action(function() 
		log("$name: v$version")
		os.exit(0)
	end)

	args = parser:parse()

	if #args.releaseFolders > 0 then
		releaseFolders = args.releaseFolders
	end
	if #args.releaseFiles > 0 then
		releaseFiles = args.releaseFiles
	end
end

--===== local functions =====--
local function log(...)
	io.write("[" .. tostring(os.date("%X")) .. "]: ")
	print(...)
end
local function verbose(level, ...)
	if tonumber(args.logLevel) >= level then
		io.write("[" .. tostring(os.date("%X")) .. "][$level]: ")
		print(...)
	end
end

local function sendRequest(url, headers, body)
	verbose(2, "Send API request to: $url")
	local request = http.new_from_uri(url)
	local responseHeaders, responseStatus, responseBody, responseError
	local stream

	do --make all upsert names lowercase
		local orgHeaderUpsert = request.headers.upsert
		request.headers.upsert = function(self, name, value)
			orgHeaderUpsert(self, string.lower(name), value)
		end
	end
	for i, v in pairs(headers) do
		if i:lower() ~= "auth" and i:lower() ~= "authorization" or args.noAuthCensor then
			verbose(3, "Add header: $i, $v")
		else
			verbose(3, "Add header (Censored): $i, TOKEN")
		end
		request.headers:upsert(i, v)
	end
	verbose(4, "Body: $body")
	request:set_body(body)
	responseHeaders, stream = request:go()
	if responseHeaders == nil then
		io.stderr:write(tostring(stream))
		io.stderr:flush()
		os.exit(1)
	elseif responseHeaders:get(":status") ~= "201" then
		responseBody, responseError = stream:get_body_as_string()
		log("API returned an error\n\n")
		io.stderr:write("Headers: ", ut.tostring(responseHeaders), "\n\n")
		io.stderr:write("Body dump: ", responseBody, "\n\n")
		io.stderr:flush() --in case the body decodeation fails.
		io.stderr:write("Body: ", ut.tostring(json.decode(responseBody)), "\n\n")
		io.stderr:flush()
		os.exit(2)
	end
	responseBody, responseError = stream:get_body_as_string()
	return responseHeaders, json.decode(responseBody)
end

local function uploadFile(path, name, fileType)
	if fileType == "directory" then
		log("Upload $fileType: ${select(2, ut.seperatePath(name))}")
	else
		log("Upload $fileType: $name")
	end
	local _, file, ending = ut.seperatePath(name)
	local responseHeaders, responseTable
	local headers
	local fileHandler = io.open(path, "r")
	local fileContent = fileHandler:read("*a")
	fileHandler:close()

	if #fileContent == 0 then
		log("WARN: Skipping empty file: $path")
		return false
	end

	ending = ut.parseArgs(ending, "")
	if ending == ".gz" then
		ending = "gzip"
	end
	
	headers = {
		[":method"] = "POST",
		["X-GitHub-Api-Version"] = "2022-11-28",
		["Accept"] = "json",
		["Authorization"] = "Bearer $token",
		["content-type"] = "application/$ending"
	}
	responseHeaders, responseTable = sendRequest("${uploadUrl}?name=${file}${ending}", headers, fileContent)
end
local function processFile(pathArg)
	local fileType = lfs.attributes(pathArg).mode
	local dirName
	local path, file, ending = ut.seperatePath(pathArg)

	file = file .. ut.parseArgs(ending, "")
	if fileType == "directory" then
		dirName = file
		file = "${file}.zip"
	end
	if not uploadedFiles[file] then
		if fileType == "directory" then
			local currentWorkingDir = lfs.currentdir()
			log("Zip directory: $path/$dirName")
			lfs.chdir(path)
			os.execute("zip -r $tmpReleaseFileLocation $dirName")
			uploadFile("$tmpReleaseFileLocation", "${dirName}.zip", fileType)
			os.execute("rm $tmpReleaseFileLocation")
			lfs.chdir(currentWorkingDir)
		else
			local uploadPath = "$path/$file"
			if #path == 0 then
				uploadPath = uploadPath:sub(2)
			end
			uploadFile(uploadPath, file, fileType)
		end
		uploadedFiles[file] = true
	else
		if fileType == "directory" then
			log("WARN: Skipping $fileType: ${select(2, ut.seperatePath(path .. '/' .. file))}: file or folder with same name already uploaded")
		else
			log("WARN: Skipping $fileType: $path/$file: file already uploaded")
		end
	end
end
local function collectReleaseFiles(path, fileType)
	log("Collect ${fileType}s in: $path")
	if not lfs.attributes("$path") then
		log("ERROR: Release folder not found: $path")
		return false
	end
	for file in lfs.dir(path) do
		if file:sub(1, 1) ~= "." then
			if lfs.attributes("$path/$file").mode == fileType then
				processFile("$path/$file")
			end
		end
	end
	return true
end

--===== prog start =====--
--=== create release ===--
do
	local responseHeaders, responseTable
	local headers = {
		[":method"] = "POST",
		["X-GitHub-Api-Version"] = "2022-11-28",
		["Accept"] = "json",
		["Authorization"] = "Bearer $token",
	}
	local requestTable = {
		tag_name = args.tag,
		name = args.name,
		body = args.description,
		target_commitish = args.target,

		draft = args.draft,
		prerelease = args.prerelease,
		generate_release_notes = args.notes
	}
	log("Send release creation request")
	responseHeaders, responseTable = sendRequest(url, headers, json.encode(requestTable))
	uploadUrl = responseTable.upload_url
	do --cut uploadUrl
		local brakedPos = uploadUrl:find("{")
		uploadUrl = uploadUrl:sub(0, brakedPos - 1)
	end
end

--=== collect/upload release files ===--
verbose(1, "Process releaseFiles")
for _, file in pairs(releaseFiles) do
	verbose(1, "Release: $file")
	if not lfs.attributes(file) then
		log("ERROR: Release file not found: $file")
	else
		processFile(file)
	end
end
verbose(1, "Process releaseFolders")
for _, dir in pairs(releaseFolders) do
	if collectReleaseFiles(dir, "file") then
		collectReleaseFiles(dir, "directory")
	end
end
log("Done")