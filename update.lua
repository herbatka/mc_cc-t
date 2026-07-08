-- Replace $FILE with the file you want downloaded and set as the startup.
local url = "https://raw.githubusercontent.com/herbatka/mc_cc-t/main/$FILE.lua"
if fs.exists("startup.lua") then fs.delete("startup.lua") end
shell.run("wget", url, "startup.lua")
os.reboot()
