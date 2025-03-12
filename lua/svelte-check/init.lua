local M = {}

local default_config = {
	command = "pnpm run check",
	spinner_frames = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
	debug_mode = false,
}

local config = vim.deepcopy(default_config)
local spinner_index = 1
local spinner_timer = nil
local summary_info = "No errors or warnings found... nice!"
local collected_output = {}

local silent_print = function(msg)
	vim.api.nvim_echo({ { msg, "Normal" } }, false, {})
end

-- Helper function to find the project root
local function find_project_root()
	local current_dir = vim.fn.getcwd()
	while current_dir ~= "/" do
		if vim.fn.glob(current_dir .. "/package.json") ~= "" then
			return current_dir
		end
		current_dir = vim.fn.fnamemodify(current_dir, ":h") -- Move up one directory
	end
	return nil
end

local function start_spinner()
	if spinner_timer then
		spinner_timer:stop()
	end

	spinner_timer = vim.defer_fn(function()
		silent_print("Running Svelte Check... " .. config.spinner_frames[spinner_index])
		spinner_index = (spinner_index % #config.spinner_frames) + 1
		start_spinner()
	end, 100)
end

local function stop_spinner()
	if spinner_timer then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
	vim.o.statusline = ""
	vim.cmd("redrawstatus")
end

local function process_output()
	if config.debug_mode then
		print("Processing collected output with " .. #collected_output .. " lines")
	end

	local quickfix_list = {}
	local error_count = 0
	local warning_count = 0
	local file_count = 0
	-- Removed unused variable files_with_problems

	for _, line in ipairs(collected_output) do
		if config.debug_mode then
			print("Processing line: " .. line)
		end

		local timestamp = line:match("^%d+")
		if not timestamp then
			if config.debug_mode then
				print("Skipped non-epoch line: " .. line)
			end
			goto continue
		end

		-- Check for completion summary
		if line:match("COMPLETED") then
			local stats_pattern =
				"^%d+%s+COMPLETED%s+(%d+)%s+FILES%s+(%d+)%s+ERRORS%s+(%d+)%s+WARNINGS%s+(%d+)%s+FILES_WITH_PROBLEMS"
			local f, e, w, _ = line:match(stats_pattern) -- Capture but don't use files_with_problems

			-- Fix type conversion issues by ensuring values are integers
			if f and e and w then
				f = tonumber(f) or 0
				e = tonumber(e) or 0
				w = tonumber(w) or 0

				file_count = f
				error_count = e
				warning_count = w

				if config.debug_mode then
					print(
						"Found stats: "
							.. file_count
							.. " files, "
							.. error_count
							.. " errors, "
							.. warning_count
							.. " warnings"
					)
				end
			else
				if config.debug_mode then
					print("Could not extract all stats from COMPLETED line: " .. line)
				end
			end
			goto continue
		end

		-- Check for errors and warnings
		local error_type, file_path, line_number, column_number, description =
			line:match('^%d+%s+(%a+)%s+"(.-)"%s+(%d+):(%d+)%s+"(.-)"')

		if error_type and file_path and line_number and column_number and description then
			-- Ensure values are properly converted to numbers
			local lnum = tonumber(line_number) or 0
			local col = tonumber(column_number) or 0

			table.insert(quickfix_list, {
				filename = file_path,
				lnum = lnum,
				col = col,
				text = description,
				type = error_type:sub(1, 1), -- E for Error, W for Warning
				nr = 0,
				valid = true,
			})

			if config.debug_mode then
				print("Added quickfix entry: " .. error_type .. " in " .. file_path .. " at " .. lnum .. ":" .. col)
			end
		else
			if config.debug_mode then
				print("No error pattern match for line: " .. line)
			end
		end

		::continue::
	end

	-- Update summary based on collected statistics or quickfix entries
	if error_count > 0 or warning_count > 0 or #quickfix_list > 0 then
		if error_count > 0 or warning_count > 0 then
			summary_info = "Svelte Check completed with "
				.. error_count
				.. " errors and "
				.. warning_count
				.. " warnings in "
				.. file_count
				.. " files."
		else
			-- Fallback if we have quickfix entries but no summary stats
			local qf_errors = 0
			local qf_warnings = 0
			for _, item in ipairs(quickfix_list) do
				if item.type == "E" then
					qf_errors = qf_errors + 1
				elseif item.type == "W" then
					qf_warnings = qf_warnings + 1
				end
			end
			summary_info = "Svelte Check completed with " .. qf_errors .. " errors and " .. qf_warnings .. " warnings."
		end
	else
		summary_info = "No errors or warnings found... nice!"
	end

	if #quickfix_list > 0 then
		vim.fn.setqflist({}, "r", { title = "Svelte Check", items = quickfix_list })
		vim.cmd("copen")
	else
		vim.fn.setqflist({}, "r", { title = "Svelte Check", items = {} })
	end

	return #quickfix_list > 0
end

M.run = function()
	start_spinner()
	collected_output = {}

	-- Find the project root directory
	local project_root = find_project_root()
	if not project_root then
		print("Could not find project root with package.json. Running in the current directory.")
		project_root = vim.fn.getcwd() -- Fallback to the current directory
	end

	if config.debug_mode then
		print("Running command in directory: " .. project_root)
	end

	local final_command = config.command .. " --output machine"

	if config.debug_mode then
		print("Running command: " .. final_command)
	end

	local job_id = vim.fn.jobstart(final_command, {
		cwd = project_root, -- Run the command in the project root directory
		stdout_buffered = false, -- Process output line by line
		stderr_buffered = false,
		on_stdout = function(_, data)
			if data and #data > 0 then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						table.insert(collected_output, line)
						if config.debug_mode then
							print("Received output: " .. line)
						end
					end
				end
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 0 then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						if config.debug_mode then
							print("stderr: " .. line)
						end
					end
				end
			end
		end,
		on_exit = function(_, exit_code)
			stop_spinner()

			local has_errors = process_output()

			print(summary_info)

			if exit_code > 1 then
				print("Svelte Check failed with exit code " .. exit_code)
			elseif exit_code == 1 and not has_errors then
				print(
					"Svelte Check exited with code 1 but no errors were captured. This might indicate a parsing issue."
				)
			end
		end,
	})

	if job_id <= 0 then
		stop_spinner()
		print("Failed to start Svelte Check process!")
	end
end

function M.setup(user_config)
	if user_config then
		config = vim.tbl_deep_extend("force", config, user_config)
	end

	vim.api.nvim_create_user_command("SvelteCheck", function()
		M.run()
	end, { desc = "Run `svelte-check` asynchronously and load the results into a qflist", force = true })
end

return M
