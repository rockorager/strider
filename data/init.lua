-- An example configuration for Strider.
--
-- Copy it to $XDG_CONFIG_HOME/strider/init.lua (~/.config/...) and
-- change what you like; without one, these defaults apply anyway. The
-- file runs once at startup in Lua 5.5. require("strider") is the file manager;
-- require("siv") is the siv toolkit's own Lua binding, for timers, jobs,
-- notifications, D-Bus and the like (strider.siv_app() is the running app).
--
-- Every key runs a named command; `:help` (or g? or F1) lists them all,
-- and `:` runs one by hand, with Tab completing names and paths.

local strider = require("strider")

-- Options (also `:set name value` while running).
strider.set {
	hidden = false, -- zh toggles
	sort = "name", -- name, size, modified, type, extension
	sort_reverse = false,
	dirs_first = true,
	ratio = { 1, 3, 4 }, -- parent, current, preview
	fit_parent = true, -- the parent widens to its names, up to a quarter
	narrow_width = 640, -- narrower windows hide the parent column
	icons = true,
	preview = true,
	which_key_delay = 300, -- ms before the key hints show after a prefix
	scroll_off = 3,
	confirm_delete = true,
}
-- strider.opt is the same, one at a time:
strider.opt.syntax = true

-- Keys: strider.map(mode, keys, command or function, description).
-- Modes are "n" (normal) and "v" (visual); a table maps both.
strider.map("n", "gp", "cd ~/Projects", "Projects")
strider.map("n", "gs", "cd ~/Pictures/Screenshots", "Screenshots")
strider.map({ "n", "v" }, "<C-c>", "yank", "Copy")

-- A Lua function gets the count typed before the keys (or nil).
strider.map("n", "gi", function(count)
	local n = #strider.selected()
	strider.notify(("%d item%s under the cursor or marked"):format(n, n == 1 and "" or "s"))
end, "How many targets")

-- strider.unmap("n", "dD") would remove a default binding.

-- Commands: run them with `:name args`, bind them, or call strider.exec.
strider.command("archive", function(args)
	local name = args ~= "" and args or "archive.tar.gz"
	-- shell runs in the current folder with the targets as "$@".
	strider.exec("shell tar -czf " .. ("%q"):format(name) .. ' "$@"')
end, "Pack the targets into a tarball")
strider.map("n", "ca", "archive", "Pack into archive.tar.gz")

-- Previewers: by file name (a glob), MIME type ("text/*" works), or a
-- match function; `run` returns the text to show, `cmd` shows a
-- program's output ("%s" is the file). Later ones win.
strider.previewer {
	name = "*.csv",
	run = function(path)
		local out, n = {}, 0
		for line in io.lines(path) do
			n = n + 1
			if n > 200 then break end
			out[#out + 1] = line:gsub(",", "  │  ")
		end
		return table.concat(out, "\n")
	end,
}
-- strider.previewer { mime = "video/*", cmd = { "mediainfo", "%s" } }

-- Bookmarks: ' and a key jumps, m and a key sets.
strider.bookmark("c", os.getenv("HOME") .. "/.config")

-- Events: "cd" runs with the folder entered.
strider.on("cd", function(path)
	-- strider.notify("Now in " .. path)
end)
