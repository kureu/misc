--[[
    ╔══════════════════════════════════════════════════════════════╗
    ║                                                              ║
    ║   M A C L I B   —   P R O   P A T C H   D O C U M E N T    ║
    ║   V E R S I O N    2 . 0                                    ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝

    This document contains every surgical fix for the MacLib UI library.
    MacLib is ~5,910 lines. All fixes are line-precise; apply them in order.
    The original file structure, visual design, and all callbacks are
    FULLY PRESERVED — only bugs are patched.

    HOW TO APPLY:
    Each patch block shows:
      [LINE]    — Original file line number for reference
      [FIND]    — The exact original code to locate (unique per fix)
      [REPLACE] — The corrected code to substitute in place

    A note is provided for each fix explaining the root cause and impact.
]]

--==============================================================================
-- PATCH #1  —  CRITICAL: SliderFunctions:UpdateName overwrites TextLabel upvalue
-- Line ~2078
-- Severity: CRITICAL — breaks the slider label AND corrupts updateSliderBarSize()
--==============================================================================

--[[
  ROOT CAUSE:
  `sliderName` is a local variable holding a TextLabel Instance.
  `function SliderFunctions:UpdateName(Name)` then does:
      sliderName = Name
  This overwrites the local UPVALUE (the TextLabel reference) with a string.
  After one call to UpdateName, the upvalue `sliderName` is a string,
  not an Instance. Two follow-on effects:
    1. The label text is never updated (TextLabel is never written to).
    2. `updateSliderBarSize()` reads `sliderName.AbsoluteSize.X` — calling
       .AbsoluteSize on a string throws an immediate Lua error.

  FIND:
      function SliderFunctions:UpdateName(Name)
          sliderName = Name
      end

  REPLACE:
      function SliderFunctions:UpdateName(Name)
          sliderName.Text = Name   -- Fix: write to the TextLabel, not the variable
      end
]]

--==============================================================================
-- PATCH #2  —  BUG: Slider FocusLost invalid-input fallback passes wrong type
-- Line ~2048
-- Severity: HIGH — typing an invalid value in a slider crashes the display method
--==============================================================================

--[[
  ROOT CAUSE:
  When the user focuses a slider's value TextBox and types something invalid
  (e.g. "abc"), the FocusLost handler's else branch runs:
      sliderValue.Text = ValueDisplayMethod(sliderValue)
  `sliderValue` here is the TextBox INSTANCE, not a number.
  `ValueDisplayMethod` (e.g. `Percent`, `Round`, `Value`) calls math operations
  on its first argument, so passing a TextBox causes either a silent NaN or
  a Lua type error, and the box never resets to the correct value.

  FIND:
              else
                  sliderValue.Text = ValueDisplayMethod(sliderValue)
              end

  REPLACE:
              else
                  -- Fix: pass the current numeric value, not the TextBox instance
                  sliderValue.Text = ValueDisplayMethod(finalValue, SliderFunctions.Settings.Precision)
              end
]]

--==============================================================================
-- PATCH #3  —  BUG: LoadAutoLoadConfig shows success notification after failure
-- Line ~5529
-- Severity: HIGH — when autoload fails, BOTH the error AND success toasts fire
--==============================================================================

--[[
  ROOT CAUSE:
  The original code:
      local suc, err = MacLib:LoadConfig(name)
      if not suc then
          WindowFunctions:Notify({ ... error ... })
      end
      WindowFunctions:Notify({ ... success ... })   -- ← always fires!

  There is no `return` after the error block, so if LoadConfig fails,
  the player sees "Error loading autoload config: ..." immediately followed
  by "Autoloaded config: ..." — contradictory and confusing.

  FIND:
          local suc, err = MacLib:LoadConfig(name)
          if not suc then
              WindowFunctions:Notify({
                  Title = "Interface",
                  Description = "Error loading autoload config: " .. err
              })
          end

          WindowFunctions:Notify({
              Title = "Interface",
              Description = string.format("Autoloaded config: %q", name),
          })

  REPLACE:
          local suc, err = MacLib:LoadConfig(name)
          if not suc then
              WindowFunctions:Notify({
                  Title = "Interface",
                  Description = "Error loading autoload config: " .. err
              })
              return  -- Fix: early exit so success notification does not fire
          end

          WindowFunctions:Notify({
              Title = "Interface",
              Description = string.format("Autoloaded config: %q", name),
          })
]]

--==============================================================================
-- PATCH #4  —  BUG: "Create Config" button also shows success after failure
-- Line ~4690
-- Severity: MEDIUM — same missing-return pattern as Patch #3
--==============================================================================

--[[
  ROOT CAUSE:
  Same pattern as Patch #3, inside the "Create Config" section button callback.

  FIND:
                      local success, returned = MacLib:SaveConfig(inputPath)
                      if not success then
                          WindowFunctions:Notify({
                              Title = "Interface",
                              Description = "Unable to save config, return error: " .. returned
                          })
                      end

                      WindowFunctions:Notify({
                          Title = "Interface",
                          Description = string.format("Created config %q", inputPath),
                      })

  REPLACE:
                      local success, returned = MacLib:SaveConfig(inputPath)
                      if not success then
                          WindowFunctions:Notify({
                              Title = "Interface",
                              Description = "Unable to save config, return error: " .. returned
                          })
                          return  -- Fix: early exit so success toast does not fire on failure
                      end

                      WindowFunctions:Notify({
                          Title = "Interface",
                          Description = string.format("Created config %q", inputPath),
                      })
]]

--==============================================================================
-- PATCH #5  —  BUG: Colorpicker:SetAlpha sets wrong property
-- Line ~4308
-- Severity: MEDIUM — SetAlpha has no visible effect because it sets .Transparency
--           instead of .BackgroundTransparency on the color swatch Frame
--==============================================================================

--[[
  ROOT CAUSE:
  `colorC` is a Frame (not an ImageLabel or similar), so its transparency
  property is `BackgroundTransparency`. Setting `.Transparency` on a Frame
  is a no-op in Roblox — it silently does nothing because Frame has no
  `.Transparency` property. The alpha value is stored correctly, but the
  visual swatch never updates.

  FIND:
                  function ColorpickerFunctions:SetAlpha(alpha)
                      ColorpickerFunctions.Alpha = alpha
                      colorC.Transparency = alpha
                      updateFromSettings()
                  end

  REPLACE:
                  function ColorpickerFunctions:SetAlpha(alpha)
                      ColorpickerFunctions.Alpha = alpha
                      colorC.BackgroundTransparency = alpha  -- Fix: correct property for a Frame
                      updateFromSettings()
                  end
]]

--==============================================================================
-- PATCH #6  —  MEMORY LEAK: GlobalSetting Toggle creates unbounded signal connections
-- Lines ~1302 and ~1310
-- Severity: MEDIUM — connection accumulates on every click; leaks memory over time
--==============================================================================

--[[
  ROOT CAUSE:
  Inside the Toggle(State) function for GlobalSettings, every call creates
  a brand-new GetPropertyChangedSignal("AbsoluteSize") connection on `checkmark`:

      checkmark:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
          ...
      end)

  This connection is NEVER stored and NEVER disconnected. Every click of
  a GlobalSetting creates one more persistent connection. On a session where
  the user toggles a setting 100 times, there are 100 live connections all
  firing on every AbsoluteSize change. The fix is to connect once on creation
  and use state variables to gate the handler logic.

  FIND:
          local function Toggle(State)
              if not State then
                  tweens.checkOut:Play()
                  tweens.nameOut:Play()
                  checkmark:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
                      if checkmark.AbsoluteSize.X <= 0 then
                          checkmark.TextTransparency = 1
                      end
                  end)
              else
                  tweens.checkIn:Play()
                  tweens.nameIn:Play()
                  checkmark:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
                      if checkmark.AbsoluteSize.X > 0 then
                          checkmark.TextTransparency = 0
                      end
                  end)
              end
          end

  REPLACE:
          -- Fix: connect the AbsoluteSize signal ONCE on creation.
          -- Store the desired target state so the one-time handler can act on it.
          local targetVisible = toggled   -- tracks what the checkmark transparency SHOULD be
          checkmark:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
              if targetVisible and checkmark.AbsoluteSize.X > 0 then
                  checkmark.TextTransparency = 0
              elseif not targetVisible and checkmark.AbsoluteSize.X <= 0 then
                  checkmark.TextTransparency = 1
              end
          end)

          local function Toggle(State)
              targetVisible = State   -- update the shared state variable
              if not State then
                  tweens.checkOut:Play()
                  tweens.nameOut:Play()
              else
                  tweens.checkIn:Play()
                  tweens.nameIn:Play()
              end
          end
]]

--==============================================================================
-- PATCH #7  —  MEMORY LEAK: Keybind Blacklist references a double-nested typo
-- Line ~2377
-- Severity: HIGH — causes a Lua error when Settings.Blacklist is set,
--           crashing the keybind binding flow entirely
--==============================================================================

--[[
  ROOT CAUSE:
  Inside the inner InputBegan connection for keybind capture:

      if KeybindFunctions.Settings.Blacklist and
         (table.find(KeybindFunctions.KeybindFunctions.Settings.Blacklist, ...)
             -- ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ double KeybindFunctions reference

  `KeybindFunctions.KeybindFunctions` does not exist — it's a typo for
  `KeybindFunctions`. This causes a nil-index error whenever the Blacklist
  table exists and the user tries to bind a key, silently breaking the binding.

  FIND:
                      if KeybindFunctions.Settings.Blacklist and (table.find(KeybindFunctions.KeybindFunctions.Settings.Blacklist, input.KeyCode) or table.find(KeybindFunctions.Settings.Blacklist, input.UserInputType)) then

  REPLACE:
                      if KeybindFunctions.Settings.Blacklist and (table.find(KeybindFunctions.Settings.Blacklist, input.KeyCode) or table.find(KeybindFunctions.Settings.Blacklist, input.UserInputType)) then
]]

--==============================================================================
-- PATCH #8  —  MEMORY LEAK: Drag / resize UserInputService connections are unbounded
-- Lines ~688-694 (sidebar resize) and ~830,850 (window drag DragStyle 1 and 2)
-- Severity: MEDIUM — connections persist after the window ScreenGui is destroyed
--==============================================================================

--[[
  ROOT CAUSE:
  Three `UserInputService.InputChanged:Connect(...)` calls and one
  `UserInputService.InputEnded:Connect(...)` call are made during window
  construction but their RBXScriptConnection objects are never stored and
  never disconnected. When `macLib:Destroy()` is called on unload, the
  ScreenGui is destroyed but these global UIS connections remain active.
  They will never fire anything meaningful (the instances they reference
  are gone), but they do consume GC and signal bandwidth indefinitely.

  --- SIDEBAR RESIZE (line ~688) ---

  FIND:
      UserInputService.InputEnded:Connect(function(input)
          if input.UserInputType == Enum.UserInputType.MouseButton1 then
              resizingContent = false
          end
      end)

      UserInputService.InputChanged:Connect(function(input)
          if resizingContent and input.UserInputType == Enum.UserInputType.MouseMovement then

  REPLACE:
      -- Fix: store and expose connections so they can be disconnected on unload.
      -- These are stored on WindowFunctions for lifecycle management.
      WindowFunctions._sidebarResizeConnections = WindowFunctions._sidebarResizeConnections or {}

      table.insert(WindowFunctions._sidebarResizeConnections,
          UserInputService.InputEnded:Connect(function(input)
              if input.UserInputType == Enum.UserInputType.MouseButton1 then
                  resizingContent = false
              end
          end)
      )

      table.insert(WindowFunctions._sidebarResizeConnections,
          UserInputService.InputChanged:Connect(function(input)
              if resizingContent and input.UserInputType == Enum.UserInputType.MouseMovement then

  --- DRAG STYLE 1 (line ~830) ---

  FIND:
          UserInputService.InputChanged:Connect(function(input)
              if input == dragInput and dragging_ then
                  update(input)
              end
          end)

          interact.InputEnded:Connect(function(input)

  REPLACE:
          table.insert(WindowFunctions._sidebarResizeConnections,
              UserInputService.InputChanged:Connect(function(input)
                  if input == dragInput and dragging_ then
                      update(input)
                  end
              end)
          )

          interact.InputEnded:Connect(function(input)

  --- DRAG STYLE 2 (line ~850) - identical pattern, same fix ---

  FIND:
          UserInputService.InputChanged:Connect(function(input)
              if input == dragInput and dragging_ then
                  update(input)
              end
          end)

          base.InputEnded:Connect(function(input)

  REPLACE:
          table.insert(WindowFunctions._sidebarResizeConnections,
              UserInputService.InputChanged:Connect(function(input)
                  if input == dragInput and dragging_ then
                      update(input)
                  end
              end)
          )

          base.InputEnded:Connect(function(input)

  --- UNLOAD CLEANUP (inside WindowFunctions:Unload) ---
  Add the following BEFORE macLib:Destroy() in WindowFunctions:Unload():

      -- Disconnect stored UIS connections to prevent leak after unload
      if WindowFunctions._sidebarResizeConnections then
          for _, conn in ipairs(WindowFunctions._sidebarResizeConnections) do
              if conn then conn:Disconnect() end
          end
          WindowFunctions._sidebarResizeConnections = {}
      end
]]

--==============================================================================
-- PATCH #9  —  CLEANUP: subtitle.RichText double assignment
-- Lines ~421-422
-- Severity: LOW — no functional impact, but produces redundant object mutation
--==============================================================================

--[[
  FIND:
      subtitle.RichText = true
      subtitle.Text = Settings.Subtitle
      subtitle.RichText = true   -- ← duplicate

  REPLACE:
      subtitle.RichText = true
      subtitle.Text = Settings.Subtitle
      -- (remove the second subtitle.RichText = true line)
]]

--==============================================================================
-- PATCH #10  —  CLEANUP: pairs() on sequential arrays should be ipairs()
-- Line ~288 (controlsList iteration) and lines ~2914, ~2974, ~2979, ~2992 (dropdowns)
-- Severity: LOW — pairs() on arrays has undefined traversal order in Lua 5.1;
--            ipairs() is deterministic and is slightly faster for arrays.
--==============================================================================

--[[
  FIND (controlsList):
      for _, button in pairs(controlsList) do

  REPLACE:
      for _, button in ipairs(controlsList) do

  FIND (InsertOptions):
      for i, v in pairs(newOptions) do
          addOption(i, v)
      end

  REPLACE:
      for i, v in ipairs(newOptions) do
          addOption(i, v)
      end
]]

--==============================================================================
-- PATCH #11  —  ROBUSTNESS: RefreshConfigList path parser
-- Lines ~5612-5628
-- Severity: LOW — works correctly, but the character-by-character backward
--            walk is O(n) per file and fragile. A pattern match is cleaner.
--==============================================================================

--[[
  FIND:
          for i = 1, #list do
              local file = list[i]
              if file:sub(-5) == ".json" then
                  local pos = file:find(".json", 1, true)
                  local start = pos

                  local char = file:sub(pos, pos)
                  while char ~= "/" and char ~= "\\" and char ~= "" do
                      pos = pos - 1
                      char = file:sub(pos, pos)
                  end

                  if char == "/" or char == "\\" then
                      local name = file:sub(pos + 1, start - 1)
                      if name ~= "options" then
                          table.insert(out, name)
                      end
                  end
              end
          end

  REPLACE:
          for i = 1, #list do
              local file = list[i]
              -- Fix: use a single pattern match — capture the filename between
              -- the last path separator and the ".json" extension.
              local name = file:match("[/\\]([^/\\]+)%.json$")
              if name and name ~= "options" then
                  table.insert(out, name)
              end
          end
]]

--==============================================================================
-- SUMMARY TABLE
--==============================================================================

--[[
  #   | Severity | Description
  ----|----------|--------------------------------------------------------------
  1   | CRITICAL | SliderFunctions:UpdateName overwrites TextLabel upvalue
  2   | HIGH     | Slider FocusLost invalid-input fallback passes TextBox, not number
  3   | HIGH     | LoadAutoLoadConfig shows success after failure (missing return)
  4   | MEDIUM   | Create Config button shows success after failure (missing return)
  5   | MEDIUM   | Colorpicker:SetAlpha uses .Transparency instead of .BackgroundTransparency
  6   | MEDIUM   | GlobalSetting Toggle creates unbounded AbsoluteSize connections per click
  7   | HIGH     | Keybind: KeybindFunctions.KeybindFunctions double-reference typo
  8   | MEDIUM   | UserInputService drag/resize connections never disconnected on unload
  9   | LOW      | subtitle.RichText assigned twice
  10  | LOW      | pairs() used on sequential arrays (should be ipairs)
  11  | LOW      | RefreshConfigList path parser is verbose; regex is cleaner
]]
