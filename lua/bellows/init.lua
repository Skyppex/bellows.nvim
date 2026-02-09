--- @alias bufnr integer
--- @alias row integer
--- @alias item_count integer
--- @alias hl_group string
---
--- @class Bellows
--- @field config BellowsOpts
--- @field default_config BellowsOpts
--- @field state BellowsState
--- @field enable_rendering function
--- @field disable_rendering function
--- @field is_on_closed_fold function<boolean>
--- @field fold_closest_block function
--- @field fold_closest_array function
--- @field fold_closest_object function
--- @field unfold_closest_block function
--- @field unfold_closest_array function
--- @field unfold_closest_object function
--- @field fold_closest_block_recursive function
--- @field fold_closest_array_recursive function
--- @field fold_closest_object_recursive function
--- @field unfold_closest_block_recursive function
--- @field unfold_closest_array_recursive function
--- @field unfold_closest_object_recursive function
--- @field render function<bufnr>
--- @field jump_next_closed_fold function
--- @field jump_prev_closed_fold function
--- @field foldtext function<table<string, hl_group>>
--- @field setup function<BellowsOpts>

--- @type Bellows
local M = {}

--- @class BellowsOpts
--- @field array_count_threshold integer minimum count before displaying the count
--- @field array_count_threshold_folded integer minimum count before display the count when folded
--- @field line_count boolean if number of lines should be shown when folded
--- @field unfold_single_item_arrays boolean recursively unwrap arrays with only one item

--- @type BellowsOpts
M.default_config = {
	line_count = true,
	array_count_threshold = 3,
	array_count_threshold_folded = 0,
	unfold_single_item_arrays = true,
}

--- @type BellowsOpts
M.config = M.default_config

--- @class BellowsState
--- @field rendering_enabled boolean
--- @field array_counts table<bufnr, table<row, item_count>>
M.state = {
	rendering_enabled = true,
	array_counts = {},
}

local ns = vim.api.nvim_create_namespace("bellows-arrays")

local function count_array_items(array_node)
	local n = 0

	for child in array_node:iter_children() do
		if
			child:type() == "array"
			or child:type() == "object"
			or child:type() == "string"
			or child:type() == "number"
			or child:type() == "true"
			or child:type() == "false"
			or child:type() == "null"
		then
			n = n + 1
		end
	end

	return n
end

local ts = vim.treesitter

local function get_node_at_position(bufnr, row, col, kind)
	local parser = ts.get_parser(bufnr, "json")

	if parser == nil then
		vim.notify("treesitter parser for language 'json' not found", vim.log.levels.WARN)
		return
	end

	local tree = parser:parse()[1]

	if not tree then
		return
	end

	local root = tree:root()

	local node = root:named_descendant_for_range(row, col, row, col)

	-- smallest enclosing block
	node = root:named_descendant_for_range(row, col, row, col)
	local candidate
	local best_size

	while node do
		local t = node:type()

		if (not kind or t == kind) and (t == "array" or t == "object") then
			local sr, _, er, _ = node:range()
			local size = er - sr

			if not candidate or size < best_size then
				candidate = node
				best_size = size
			end
		end

		node = node:parent()
	end

	return candidate
end

local function get_target_node(kind) -- kind = nil | "array" | "object"
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] - 1

	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local col = #line

	if line:sub(-1) == "," and col > 0 then
		col = col - 2
	end

	return get_node_at_position(bufnr, row, col, kind)
end

local function fold_node(node)
	if not node then
		return
	end

	local sr, _, er, _ = node:range()

	if er > sr then
		vim.cmd((sr + 1) .. "," .. (er + 1) .. "fold")
	end
end

local function unfold_node(node)
	if not node then
		return
	end

	local start_row, _, _, _ = node:range()
	start_row = start_row + 1 -- convert to 1-based Vim lines

	-- keep opening folds at this line until there are no more closed folds covering it
	while vim.fn.foldclosed(start_row) ~= -1 do
		vim.cmd(start_row .. "normal! zo")
	end

	local function unwrap_if_single_item(current_node)
		local t = current_node:type()

		if t ~= "array" then
			return
		end

		local count = count_array_items(current_node)

		if count ~= 1 then
			return
		end

		local child = current_node:named_child(0)
		unfold_node(child)
		unwrap_if_single_item(child)
	end

	if M.config.unfold_single_item_arrays then
		unwrap_if_single_item(node)
	end
end

local function fold_node_recursive(node)
	if not node then
		return
	end

	for child in node:iter_children() do
		local t = child:type()

		if t == "pair" then
			child = child:field("value")[1]
			t = child:type()
		end

		if t == "array" or t == "object" then
			fold_node_recursive(child)
		end
	end

	fold_node(node)
end

local function unfold_node_recursive(node)
	if not node then
		return
	end

	-- first unfold current node
	unfold_node(node)

	-- then recursively unfold all children
	for child in node:iter_children() do
		local t = child:type()
		if t == "array" or t == "object" then
			unfold_node_recursive(child)
		end
	end
end

function M.enable_rendering()
	M.state.rendering_enabled = true
end

function M.disable_rendering()
	M.state.rendering_enabled = false
end

function M.is_on_closed_fold()
	local row = vim.fn.line(".")
	return vim.fn.foldclosed(row) ~= -1
end

function M.fold_closest_block()
	fold_node(get_target_node(nil))
end

function M.fold_closest_array()
	fold_node(get_target_node("array"))
end

function M.fold_closest_object()
	fold_node(get_target_node("object"))
end

function M.unfold_closest_block()
	unfold_node(get_target_node(nil))
end

function M.unfold_closest_array()
	unfold_node(get_target_node("array"))
end

function M.unfold_closest_object()
	unfold_node(get_target_node("object"))
end

function M.fold_closest_block_recursive()
	fold_node_recursive(get_target_node(nil))
end

function M.fold_closest_array_recursive()
	fold_node_recursive(get_target_node("array"))
end

function M.fold_closest_object_recursive()
	fold_node_recursive(get_target_node("object"))
end

function M.unfold_closest_block_recursive()
	unfold_node_recursive(get_target_node(nil))
end

function M.unfold_closest_array_recursive()
	unfold_node_recursive(get_target_node("array"))
end

function M.unfold_closest_object_recursive()
	unfold_node_recursive(get_target_node("object"))
end

function M.render(bufnr)
	if not M.state.rendering_enabled then
		return
	end

	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local ok, parser = pcall(ts.get_parser, bufnr, "json")

	if not ok then
		vim.notify("treesitter parser of language 'json' not found", vim.log.levels.WARN)
		return
	end

	M.state.array_counts[bufnr] = {}

	local tree = parser:parse()[1]
	if not tree then
		return
	end

	local root = tree:root()

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local query = ts.query.parse(
		"json",
		-- lang: query
		[[
			(array) @array
		]]
	)

	for _, node in query:iter_captures(root, bufnr, 0, -1) do
		local count = count_array_items(node)

		local row, col = node:start()

		M.state.array_counts[bufnr][row] = count

		if count < M.config.array_count_threshold then
			goto continue
		end

		vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
			virt_text = {
				{ (" [%d]"):format(count), "Comment" },
			},
			virt_text_pos = "eol",
		})

		::continue::
	end
end

function M.jump_next_closed_fold()
	local row = vim.fn.line(".")
	local last_line = vim.fn.line("$")

	-- if cursor is inside a closed fold, skip to the line after the fold
	local fold_start = vim.fn.foldclosed(row)
	if fold_start ~= -1 then
		local fold_end = vim.fn.foldclosedend(row)
		row = fold_end
	end

	for r = row + 1, last_line do
		local start = vim.fn.foldclosed(r)
		if start ~= -1 then
			-- jump to the fold start
			vim.api.nvim_win_set_cursor(0, { start, 0 })
			return true
		end
	end

	return false
end

function M.jump_prev_closed_fold()
	local row = vim.fn.line(".")

	-- if cursor is inside a closed fold, skip to the line before the fold
	local fold_start = vim.fn.foldclosed(row)
	if fold_start ~= -1 then
		row = fold_start - 1
	else
		row = row - 1
	end

	for r = row, 1, -1 do
		local start = vim.fn.foldclosed(r)
		if start ~= -1 then
			-- jump to the fold start
			vim.api.nvim_win_set_cursor(0, { start, 0 })
			return true
		end
	end

	return false
end

function M.foldtext()
	local bufnr = vim.api.nvim_get_current_buf()

	local start_lnum = vim.v.foldstart
	local start0 = start_lnum - 1

	local line = vim.fn.getline(start_lnum):gsub("\t", string.rep(" ", vim.o.tabstop))

	local result = {}

	local last_hl = nil
	local bracket_hl = nil
	local brace_hl = nil
	local text = ""

	local opener = nil

	for i = 1, #line do
		local ch = line:sub(i, i)

		local caps = ts.get_captures_at_pos(bufnr, start0, i - 1)
		local cap = caps[1]
		local hl = cap and ("@" .. cap.capture) or nil

		if ch == "[" and hl and not bracket_hl then
			bracket_hl = hl
			opener = "["
		elseif ch == "{" and hl and not brace_hl then
			brace_hl = hl
			opener = "{"
		end

		if hl ~= last_hl then
			if #text > 0 then
				table.insert(result, { text, last_hl })
			end
			text = ""
			last_hl = hl
		end

		text = text .. ch
	end

	if #text > 0 then
		table.insert(result, { text, last_hl })
	end

	local count = M.state.array_counts and M.state.array_counts[bufnr] and M.state.array_counts[bufnr][start0]

	local double_dot_hl = "Folded"

	if opener == "[" then
		table.insert(result, { " .. ", double_dot_hl })
		table.insert(result, { "]", bracket_hl })

		if count >= M.config.array_count_threshold_folded then
			table.insert(result, { (" [%d]"):format(count), "Comment" })
		end
	elseif opener == "{" then
		table.insert(result, { " .. ", double_dot_hl })
		table.insert(result, { "}", brace_hl })
	end

	if M.config.line_count then
		local line_count = vim.v.foldend - vim.v.foldstart + 1
		table.insert(result, { (" lines: %d"):format(line_count), "Comment" })
	end

	table.insert(result, { " " })

	return result
end

--- @param opts? BellowsOpts
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.default_config, opts or {})

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "TextChanged", "TextChangedI" }, {
		callback = function(args)
			local filetype = vim.api.nvim_get_option_value("filetype", { buf = args.buf })

			if filetype ~= "json" then
				return
			end

			vim.wo.foldtext = "v:lua.require('bellows').foldtext()"
			M.render(args.buf)
		end,
	})
end

return M
