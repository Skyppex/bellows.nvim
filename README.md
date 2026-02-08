# bellows.nvim

bellows helps you comb through your large json files using treesitter to make
folding and unfolding easy and snappy

## installation

with lazy.nvim

```lua
return {
	"skyppex/bellows.nvim",
	config = function()
		-- configure bellows
		--- @type BellowsOpts
		local opts = {
			-- if the number of folded lines is displayed
			line_count = true,
			-- when to start showing the number of items in the array
			array_count_threshold = 3,
			-- when to start showing the number of items in the array when its folded
			array_count_threshold_folded = 0,
		}

		require("bellows").setup(opts)
	end,
}
```

## usage

the `bellows` lua api provides several functions to help you control what you
see in the file

```lua
-- import bellows and optionally give it its type for some lsp help
--- @type Bellows
local bellows = require("bellows")

-- folds the closest array or object
vim.keymap.set("n", "<leader>zb", bellows.fold_closest_block())

-- finds the closest array with treesitter and creates
-- folds for it and all nested structures
-- note that the array specific variant will only search for arrays to find the
-- top-level scope. it will then make folds for both arrays and objects regardless
vim.keymap.set("n", "<leader>Z]", bellows.fold_closest_array_recursive())

-- see the Bellows type for a comprehensive list of all available functions
```

## contributing

issues and pull requests are welcome! please make an issue for feature requests
before doing any work on a pr

## license - MIT

see LICENSE file
