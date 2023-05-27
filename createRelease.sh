#!/usr/bin/pleal

--[[
	GithubReleaseHelper Copyright (C) 2023  MisterNoNameLP

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

local version = "1.0.1"
local name = "GithubReleaseHelper"

--===== conf =====--
local url = "https://api.github.com/repos/OpenPlayVerse/test/releases" --repo URL/releases
local releaseFolders = {} --overwritten by the -R argument
local tokenPath = "ghAPI.token" --path to file containing the bearer token
local tmpReleaseFileLocation = ".compressedReleaseFiles.zip" --relative to the releaseFolders if starting with a dot. its recommended to have this on a ramfs

--===== runtime vars =====--
local http = require("http.request")
local ut = require("UT")
local json = require("json")
local argparse = require("argparse")
local len = require("utf8").len
local lfs = require("lfs")

local args
local token = ut.readFile("ghAPI.token")
local uploadUrl
local uploadedFiles = {}

--===== init =====--
do --arg parsing 
	local parser = argparse(name)

	parser:option("-t --tag", "Release tag"):count(1):args(1):target("tag")
	parser:option("-n --name", "Relase name"):count(1):args(1):target("name")
	parser:option("-d --description", "Relase description"):count(1):args(1):target("description")
	parser:option("-T --target", "Target branch"):count(1):args(1):target("target")
	
	parser:flag("-D --draft", "Draft"):target("draft")
	parser:flag("-P --prerelease", "Prerelease"):target("prerelease")
	parser:flag("-G --generate-release-notes", "Generate release notes"):target("notes")

	parser:option("-R --release-folders", "Folder in wich release files are stored"):count("*"):target("releaseFolders")

	parser:flag("-v --version", "log version and exit"):action(function() 
		log("$name: v$version")
		os.exit(0)
	end)

	parser:option("--log-level", "Set the log level (0-2)"):default(0):target("logLevel")

	args = parser:parse()

	if #args.releaseFolders > 0 then
		releaseFolders = args.releaseFolders
	end
end

--===== local functions =====--
local function log(...)
	io.write("[" .. tostring(os.date("%X")) .. "]: ")
	print(...)
end
local function verboseLog(level, ...)
	if tonumber(args.logLevel) >= level then
		io.write("[" .. tostring(os.date("%X")) .. "][$level]: ")
		print(...)
	end
end

local function sendRequest(url, headers, body)
	log("Send API request to: $url")

	local request = http.new_from_uri(url)
	local responseHeaders, responseStatus, responseBody, responseError
	local stream

	verboseLog(1, "Build headers")
	do --make all upsert names lowercase
		local orgHeaderUpsert = request.headers.upsert
		request.headers.upsert = function(self, name, value)
			orgHeaderUpsert(self, string.lower(name), value)
		end
	end
	for i, v in pairs(headers) do
		if i:lower() ~= "auth" and i:lower() ~= "authorization" then
			verboseLog(2, "Add header: $i, $v")
		else
			verboseLog(2, "Add header (Censored): $i, TOKEN")
		end
		request.headers:upsert(i, v)
	end
	verboseLog(1, "Add body")
	verboseLog(2, "Body: $body")
	request:set_body(body)
	verboseLog(1, "Send request")
	verboseLog(1, "Process response")
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
	log("Upload $fileType: $path")
	local _, file, ending = ut.seperatePath(name)
	local responseHeaders, responseTable
	local headers
	local fileHandler = io.open(path, "r")

	if ending == ".gz" then
		ending = "gzip"
	end
	
	verboseLog(1, "Build release file request")
	headers = {
		[":method"] = "POST",
		["X-GitHub-Api-Version"] = "2022-11-28",
		["Accept"] = "json",
		["Authorization"] = "Bearer $token",
		["content-type"] = "application/$ending"
	}
	responseHeaders, responseTable = sendRequest("${uploadUrl}?name=${file}${ending}", headers, fileHandler:read("*a"))
	fileHandler:close()
end
local function collectReleaseFiles(path, fileType)
	log("Prepare ${fileType}s from: $path")
	local dirName
	if not lfs.attributes("$path") then
		log("ERROR: Release folder not found: $path")
		return false
	end
	for file in lfs.dir(path) do
		if file:sub(1, 1) ~= "." then
			if lfs.attributes("$path/$file").mode == fileType then
				if fileType == "directory" then
					dirName = file
					file = "${file}.zip"
				end
				if not uploadedFiles[file] then
					if fileType == "directory" then
						local currentWorkingDir = lfs.currentdir()
						log("Zip dir: $path/$dirName")
						lfs.chdir(path)
						os.execute("zip -r $tmpReleaseFileLocation $dirName")
						uploadFile("$tmpReleaseFileLocation", "${dirName}.zip", fileType)
						os.execute("rm $tmpReleaseFileLocation")
						lfs.chdir(currentWorkingDir)
					else
						uploadFile("$path/$file", file, fileType)
					end
					uploadedFiles[file] = true
				else
					log("Skipping $fileType: $path/$file: file already uploaded")
				end
			end
		end
	end
	return true
end

--===== prog start =====--
--=== create release ===--
do
	local responseHeaders, responseTable
	log("Build release creation request")
	local headers = {
		[":method"] = "POST",
		["X-GitHub-Api-Version"] = "2022-11-28",
		["Accept"] = "json",
		["Authorization"] = "Bearer $token",
	}
	log("Build body")

	local requestTable = {
		tag_name = args.tag,
		name = args.name,
		body = args.description,
		target_commitish = args.target,

		draft = args.draft,
		prerelease = args.prerelease,
		generate_release_notes = args.notes
	}
	responseHeaders, responseTable = sendRequest(url, headers, json.encode(requestTable))
	uploadUrl = responseTable.upload_url
	do --cut uploadUrl
		local brakedPos = uploadUrl:find("{")
		uploadUrl = uploadUrl:sub(0, brakedPos - 1)
	end
end

--=== collect/upload release files ===--
log("Prepare release folders")
for _, dir in pairs(releaseFolders) do
	log("Process release folder: $dir")
	if collectReleaseFiles(dir, "file") then
		collectReleaseFiles(dir, "directory")
	end
end
log("Done")