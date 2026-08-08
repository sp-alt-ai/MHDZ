-- MHDZ loader
-- Replace <YOU>/<REPO> once the GitHub repo exists.
local url = "https://raw.githubusercontent.com/sp-alt-ai/MHDZ/main/MHDZ.lua"
local ok, src = pcall(function()
	return game:HttpGet(url)
end)
if not ok or type(src) ~= "string" or src == "" then
	error("MHDZ: failed to download script (check that the repo is public and MHDZ.lua is on main)")
end
local func, err = loadstring(src)
if not func then
	error("MHDZ: failed to compile downloaded script: " .. tostring(err))
end
print("MHDZ: started.")
func()
print("MHDZ: script returned (closed its loop).")