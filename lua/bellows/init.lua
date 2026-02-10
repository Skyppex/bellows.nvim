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
--- @field pin function
--- @field unpin function
--- @field is_pinned function<boolean>
--- @field clear_pins function
--- @field jump_next_pin function
--- @field jump_prev_pin function
--- @field setup function<BellowsOpts>

--- @type Bellows
local M = {}

--- @class BellowsOpts
--- @field array_count_threshold integer minimum count before displaying the count
--- @field array_count_threshold_folded integer minimum count before display the count when folded
--- @field line_count boolean if number of lines should be shown when folded
--- @field unfold_single_item_arrays boolean recursively unwrap arrays with only one item
--- @field pin_max_string_length integer max characters to show for pinned string values
--- @field pin_path_abbreviate_threshold integer path display length before abbreviating segments

--- @type BellowsOpts
M.default_config = {
	line_count = true,
	array_count_threshold = 3,
	array_count_threshold_folded = 0,
	unfold_single_item_arrays = true,
	pin_max_string_length = 30,
	pin_path_abbreviate_threshold = 20,
}

--- @type BellowsOpts
M.config = M.default_config

--- @class BellowsState
--- @field rendering_enabled boolean
--- @field array_counts table<bufnr, table<row, item_count>>
--- @field pinned_paths table<bufnr, string[]>
M.state = {
	rendering_enabled = true,
	array_counts = {},
	pinned_paths = {},
}

local ns = vim.api.nvim_create_namespace("bellows-arrays")
local ns_pins = vim.api.nvim_create_namespace("bellows-pins")
local ts = vim.treesitter

--- Given a treesitter node, extract the raw key text (without quotes).
--- @param key_node TSNode
--- @return string|nil
local function get_key_text(key_node, bufnr)
	local text = ts.get_node_text(key_node, bufnr)
	if not text then
		return nil
	end
	-- strip surrounding quotes from JSON string keys
	return text:match('^"(.*)"$') or text
end

--- Find the pair node for the cursor position.
--- First checks the exact cursor position, then scans forward on the same line
--- to find a key. Only falls back to walking up the tree if no pair is found
--- on the line ahead of the cursor.
--- @param bufnr integer
--- @param row integer 0-based
--- @param col integer 0-based
--- @return TSNode|nil pair_node
local function find_pair_at_cursor(bufnr, row, col)
	local parser = ts.get_parser(bufnr, "json")
	if not parser then
		return nil
	end

	local tree = parser:parse()[1]
	if not tree then
		return nil
	end

	local root = tree:root()
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

	local scan_start = col

	if scan_start > 1 then
		scan_start = scan_start - 1
	end

	-- scan from cursor column forward to end of line to find a pair
	for i = scan_start, #line - 1 do
		local node = root:named_descendant_for_range(row, i, row, i)

		if node == nil then
			break
		end

		if node:type() == "pair" then
			return node
		end
	end

	-- fallback: walk up from cursor position to find an enclosing pair
	local node = root:named_descendant_for_range(row, scan_start, row, scan_start)
	while node do
		if node:type() == "pair" then
			return node
		end
		node = node:parent()
	end

	return nil
end

--- Walk from a pair node up to the document root, building the full JSON path.
--- Arrays are marked with [] in the path.
--- @param pair_node TSNode
--- @param bufnr integer
--- @return string|nil path e.g. ".data.[].meta.flags.priority"
local function build_path_from_pair(pair_node, bufnr)
	local segments = {}

	-- start with the key of this pair
	local key_node = pair_node:field("key")[1]
	if not key_node then
		return nil
	end

	local key_text = get_key_text(key_node, bufnr)
	if not key_text then
		return nil
	end

	table.insert(segments, 1, key_text)

	local node = pair_node:parent()

	while node do
		local t = node:type()

		if t == "object" then
			-- check if this object is the value of a pair (i.e. has a key above it)
			local parent = node:parent()
			if parent and parent:type() == "pair" then
				local parent_key = parent:field("key")[1]
				if parent_key then
					local pk = get_key_text(parent_key, bufnr)
					if pk then
						table.insert(segments, 1, pk)
					end
				end
				-- skip past the pair node
				node = parent:parent()
			else
				node = parent
			end
		elseif t == "array" then
			-- mark that we crossed an array boundary
			table.insert(segments, 1, "[]")
			-- check if the array itself is the value of a pair
			local parent = node:parent()
			if parent and parent:type() == "pair" then
				local parent_key = parent:field("key")[1]
				if parent_key then
					local pk = get_key_text(parent_key, bufnr)
					if pk then
						table.insert(segments, 1, pk)
					end
				end
				node = parent:parent()
			else
				node = parent
			end
		else
			node = node:parent()
		end
	end

	return "." .. table.concat(segments, ".")
end

--- Resolve the full JSON path for the property at the cursor position.
--- @return string|nil path
local function resolve_path_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] - 1
	local col = cursor[2]

	local pair_node = find_pair_at_cursor(bufnr, row, col)
	if not pair_node then
		return nil
	end

	return build_path_from_pair(pair_node, bufnr)
end

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

function M.pin()
	local path = resolve_path_at_cursor()
	if not path then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	if not M.state.pinned_paths[bufnr] then
		M.state.pinned_paths[bufnr] = {}
	end

	-- don't add duplicates
	for _, p in ipairs(M.state.pinned_paths[bufnr]) do
		if p == path then
			return
		end
	end

	table.insert(M.state.pinned_paths[bufnr], path)
	M.render(bufnr)
	vim.cmd("redraw")
end

function M.unpin()
	local path = resolve_path_at_cursor()
	if not path then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local pins = M.state.pinned_paths[bufnr]
	if not pins then
		return
	end

	for i, p in ipairs(pins) do
		if p == path then
			table.remove(pins, i)
			M.render(bufnr)
			vim.cmd("redraw")
			return
		end
	end
end

function M.is_pinned()
	local path = resolve_path_at_cursor()
	if not path then
		return false
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local pins = M.state.pinned_paths[bufnr]
	if not pins then
		return false
	end

	for _, p in ipairs(pins) do
		if p == path then
			return true
		end
	end

	return false
end

function M.clear_pins()
	local bufnr = vim.api.nvim_get_current_buf()
	M.state.pinned_paths[bufnr] = {}
	M.render(bufnr)
	vim.cmd("redraw")
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

	-- render pin indicators on lines where pinned properties are defined
	vim.api.nvim_buf_clear_namespace(bufnr, ns_pins, 0, -1)

	local pins = M.state.pinned_paths[bufnr]
	if pins and #pins > 0 then
		local pair_query = ts.query.parse(
			"json",
			-- lang: query
			[[
				(pair) @pair
			]]
		)

		for _, pair_node in pair_query:iter_captures(root, bufnr, 0, -1) do
			local path = build_path_from_pair(pair_node, bufnr)
			if path then
				for _, pin in ipairs(pins) do
					if pin == path then
						local row, _ = pair_node:start()
						vim.api.nvim_buf_set_extmark(bufnr, ns_pins, row, 0, {
							virt_text = {
								{ " pinned", "DiagnosticHint" },
							},
							virt_text_pos = "eol",
						})
						break
					end
				end
			end
		end
	end
end

function M.jump_next_pin()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-based

	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_pins, { row + 1, 0 }, -1, {})
	if #marks > 0 then
		vim.api.nvim_win_set_cursor(0, { marks[1][2] + 1, 0 })
		return true
	end

	return false
end

function M.jump_prev_pin()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-based

	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_pins, { row - 1, 0 }, 0, { limit = 1 })
	if #marks > 0 then
		vim.api.nvim_win_set_cursor(0, { marks[1][2] + 1, 0 })
		return true
	end

	return false
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

--- Given a value node, produce a display string and highlight group for the foldtext.
--- Strings are truncated to pin_max_string_length, arrays show count,
--- objects show {..}, primitives shown as-is.
--- @param value_node TSNode
--- @param bufnr integer
--- @return string text, string hl_group
local function extract_value_text(value_node, bufnr)
	local t = value_node:type()

	if t == "string" then
		local raw = ts.get_node_text(value_node, bufnr)
		-- raw includes quotes, e.g. "hello world"
		local inner = raw:match('^"(.*)"$') or raw
		local max = M.config.pin_max_string_length
		if #inner > max then
			inner = inner:sub(1, max) .. "..."
		end
		return '"' .. inner .. '"', "@string.json"
	elseif t == "array" then
		local count = count_array_items(value_node)
		return "[" .. count .. "]", "@punctuation.bracket.json"
	elseif t == "object" then
		return "{..}", "@punctuation.bracket.json"
	elseif t == "number" then
		return ts.get_node_text(value_node, bufnr) or "0", "@number.json"
	elseif t == "true" or t == "false" then
		return ts.get_node_text(value_node, bufnr) or t, "@boolean.json"
	elseif t == "null" then
		return "null", "@constant.builtin.json"
	else
		return ts.get_node_text(value_node, bufnr) or "", "Folded"
	end
end

--- Build the path from the document root down to (but not including) a given node.
--- This is used to determine the "address" of a folded node in the document.
--- @param node TSNode
--- @param bufnr integer
--- @return string path e.g. ".data.[]"
local function build_path_to_node(node, bufnr)
	local segments = {}
	local current = node

	while current do
		local parent = current:parent()
		if not parent then
			break
		end

		local pt = parent:type()

		if pt == "array" then
			table.insert(segments, 1, "[]")
			-- if the array is the value of a pair, also include the key
			local grandparent = parent:parent()
			if grandparent and grandparent:type() == "pair" then
				local key = grandparent:field("key")[1]
				if key then
					local k = get_key_text(key, bufnr)
					if k then
						table.insert(segments, 1, k)
					end
				end
				current = grandparent:parent()
			else
				current = parent:parent()
			end
		elseif pt == "pair" then
			-- current node is the value of a pair, include the key
			local key = parent:field("key")[1]
			if key then
				local k = get_key_text(key, bufnr)
				if k then
					table.insert(segments, 1, k)
				end
			end
			current = parent:parent()
		else
			current = parent
		end
	end

	if #segments == 0 then
		return ""
	end

	return "." .. table.concat(segments, ".")
end

--- Given a folded node, walk into its treesitter subtree to find the value at
--- a relative path (segments like {"meta", "flags", "priority"}).
--- Handles intermediate arrays by returning nil (we don't cross array boundaries).
--- @param node TSNode the folded object/array node
--- @param path_segments string[] e.g. {"meta", "flags", "priority"}
--- @param bufnr integer
--- @return TSNode|nil value_node
local function resolve_value_in_subtree(node, path_segments, bufnr)
	local current = node

	for i, seg in ipairs(path_segments) do
		if current:type() ~= "object" then
			return nil
		end

		local found = false
		for child in current:iter_children() do
			if child:type() == "pair" then
				local key = child:field("key")[1]
				if key and get_key_text(key, bufnr) == seg then
					local value = child:field("value")[1]
					if not value then
						return nil
					end
					if i == #path_segments then
						return value
					end
					current = value
					found = true
					break
				end
			end
		end

		if not found then
			return nil
		end
	end

	return nil
end

--- Split a pin path string into segments.
--- e.g. ".data.[].meta.flags.priority" -> {"data", "[]", "meta", "flags", "priority"}
--- @param path string
--- @return string[]
local function split_path(path)
	local segments = {}
	-- strip leading dot
	local s = path:sub(2)
	for seg in s:gmatch("[^.]+") do
		table.insert(segments, seg)
	end
	return segments
end

--- Format a path for display in foldtext.
--- If the display path (with quotes and dots) exceeds the abbreviation threshold,
--- abbreviate all segments except the last to their first character.
--- @param display_segments string[] the segments to display (relative path from fold to pin)
--- @return string formatted path
local function format_pin_display(display_segments)
	if #display_segments == 0 then
		return ""
	end

	if #display_segments == 1 then
		return display_segments[1]
	end

	-- build the full version: meta.flags.priority
	local full = table.concat(display_segments, ".")

	if #full <= M.config.pin_path_abbreviate_threshold then
		return full
	end

	-- abbreviate: all segments except the last become first char only
	local abbrev = {}
	for i, seg in ipairs(display_segments) do
		if i == #display_segments then
			table.insert(abbrev, seg)
		else
			table.insert(abbrev, seg:sub(1, 1))
		end
	end

	return table.concat(abbrev, ".")
end

--- For a given folded node, find all applicable pinned paths and extract their values.
--- Returns a list of { display = string, value = string } entries.
--- Pins are shown as far up as possible without crossing an array boundary.
--- @param fold_node TSNode
--- @param bufnr integer
--- @return table[] list of { display: string, value: string }
local function get_pins_for_fold(fold_node, bufnr)
	local pins = M.state.pinned_paths[bufnr]
	if not pins or #pins == 0 then
		return {}
	end

	-- build the path TO this fold node (its address in the document)
	local fold_path = build_path_to_node(fold_node, bufnr)
	local fold_segments = split_path(fold_path)

	local results = {}

	for _, pin_path in ipairs(pins) do
		local pin_segments = split_path(pin_path)

		-- check if the fold_path is a prefix of the pin_path
		if #pin_segments <= #fold_segments then
			goto next_pin
		end

		local is_prefix = true
		for i, seg in ipairs(fold_segments) do
			if pin_segments[i] ~= seg then
				is_prefix = false
				break
			end
		end

		if not is_prefix then
			goto next_pin
		end

		-- the remaining segments are what we need to resolve inside the fold
		local remaining = {}
		for i = #fold_segments + 1, #pin_segments do
			table.insert(remaining, pin_segments[i])
		end

		-- check that we don't cross an array boundary in the remaining path
		-- (the fold node itself can be inside an array, but the remaining
		-- path segments should not contain [])
		local crosses_array = false
		for _, seg in ipairs(remaining) do
			if seg == "[]" then
				crosses_array = true
				break
			end
		end

		if crosses_array then
			goto next_pin
		end

		-- resolve the value inside the folded subtree
		local value_node = resolve_value_in_subtree(fold_node, remaining, bufnr)
		if value_node then
			local display = format_pin_display(remaining)
			local value, value_hl = extract_value_text(value_node, bufnr)
			table.insert(results, { display = display, value = value, value_hl = value_hl })
		end

		::next_pin::
	end

	return results
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

	-- get pinned values for this fold
	local pin_entries = {}
	local ok2, parser2 = pcall(ts.get_parser, bufnr, "json")
	if ok2 and parser2 then
		local tree = parser2:parse()[1]
		if tree then
			local root = tree:root()
			-- find the opener column on the fold start line (the { or [ character)
			local raw_line = vim.fn.getline(start_lnum)
			local opener_col = raw_line:find("[%{%[]")
			if opener_col then
				opener_col = opener_col - 1 -- convert to 0-based
				local node = root:named_descendant_for_range(start0, opener_col, start0, opener_col)
				-- walk up to find the array/object node that starts on this line
				while node do
					local sr, _, _, _ = node:range()
					if (node:type() == "object" or node:type() == "array") and sr == start0 then
						pin_entries = get_pins_for_fold(node, bufnr)
						break
					end
					node = node:parent()
				end
			end
		end
	end

	if opener == "[" then
		table.insert(result, { " .. ", double_dot_hl })
		table.insert(result, { "]", bracket_hl })

		if count >= M.config.array_count_threshold_folded then
			table.insert(result, { (" [%d]"):format(count), "Comment" })
		end
	elseif opener == "{" then
		if #pin_entries > 0 then
			table.insert(result, { " ", double_dot_hl })
			for _, entry in ipairs(pin_entries) do
				table.insert(result, { entry.display .. ": ", "@property.json" })
				table.insert(result, { entry.value, entry.value_hl })
				table.insert(result, { ", ", "Delimiter" })
			end
			table.insert(result, { ".. ", double_dot_hl })
			table.insert(result, { "}", brace_hl })
		else
			table.insert(result, { " .. ", double_dot_hl })
			table.insert(result, { "}", brace_hl })
		end
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
