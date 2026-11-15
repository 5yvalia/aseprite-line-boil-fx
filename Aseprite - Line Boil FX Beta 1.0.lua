-- Aseprite Line Boil FX Beta 1.0 --
-- SAFE MODE: refuse to run on canvases larger than 512x512 px
local safe_mode = true
local SAFE_MODE_MAX_WIDTH = 512
local SAFE_MODE_MAX_HEIGHT = 512
-- REFERENCES --
local sprite -- The active document this script is locked to (set at launch)
local dlg, timer, click_timer, listener
local MODIFIERS = {} -- Filled by the effect list section below. Each entry becomes one radio button

-- CONFIGURATION --
-- (Can be modified)
    local effect_index = 1 -- Effect selected at start up (position in the MODIFIERS list)
    local intensity = 1 -- Default intensity at start up (1-10)
    local density = 1 -- Default density at start up (1-10)
    local animation_fps = 4 -- Default playback speed (1-60). Also sets the duration of the selected frames on Apply
    local canvas_size = 128 -- Width and height of the preview canvas in pixels
    local collapsed = false -- If true, the options are hidden at start up. Can be toggled with the Hide / Show Options button

-- (Do not modify)
    local MIN_INTENSITY, MAX_INTENSITY = 1, 10
    local MIN_DENSITY, MAX_DENSITY = 1, 10
    local MIN_PLAYABLE_FRAMES = 2 -- Play, < and > are disabled when fewer frames than this are selected
    local MAX_LABEL_LENGTH = 32
    local is_playing = false
    local frame_current = 0
    local frame_count = 1
    local pan_x, pan_y = 0, 0
    local dragging, drag_x, drag_y = false, 0, 0
    local click_pending, click_x, click_y = false, 0, 0
    local double_click_time = 0.35
    local zoom = 5 -- Zoom level at start up when auto_fit_zoom is off. Can be changed with the mouse scroll wheel over the preview
    local auto_fit_zoom = true -- Fits the whole image inside the preview canvas at start up (overrides zoom above)
    local min_zoom, max_zoom = 0.125, 50 -- Zoom limits. Below 1 the preview is shrunk (0.5 = half size)
    local selection -- { layers, anchor, frames, name } read from the timeline
    local source_images = {} -- Full-canvas image of the selected layers, one per selected frame
    local preview_images = {} -- source_images with the current effect applied

-----------------------------------------------------------------------
-- EFFECT LIST --
-----------------------------------------------------------------------
local effect_boiling, effect_noise, effect_wave
MODIFIERS[#MODIFIERS + 1] = { id = "boiling", label = "Boiling", apply = function(image, context) return effect_boiling(image, context) end }
MODIFIERS[#MODIFIERS + 1] = { id = "wave",    label = "Wave",    apply = function(image, context) return effect_wave(image, context) end }
MODIFIERS[#MODIFIERS + 1] = { id = "noise",   label = "Noise",   apply = function(image, context) return effect_noise(image, context) end }

-----------------------------------------------------------------------
-- EFFECT MODIFIERS --
-----------------------------------------------------------------------

-- HELPERS & OPTIMIZATION --
do
  local round_down, cosine, sine, round_up = math.floor, math.cos, math.sin, math.ceil
  local smaller, larger = math.min, math.max
  local FULL_CIRCLE = math.pi * 2
  local function blend(start_value, end_value, amount) return start_value + (end_value - start_value) * amount end
  local function round_to_nearest(number) return round_down(number + 0.5) end

  local BOIL_BLOCK_SIZE = 1

  local function random_from_numbers(a, b, c)
    local scrambled = round_down(a) * 374761393 + round_down(b) * 668265263 + round_down(c) * 1442695041
    scrambled = (scrambled ~ (scrambled >> 13)) * 1274126177
    scrambled = scrambled ~ (scrambled >> 16)
    return ((scrambled >> 8) & 0xFFFF) / 65535
  end

  -- IMAGE CACHE --
  local image_info_cache = {}

  -- Returns the info for this frame, or nil if the frame is completely blank
  local function get_image_info(image, frame_index)
    local got_bytes, pixel_fingerprint = pcall(function() return image.bytes end)
    if not got_bytes then pixel_fingerprint = nil end

    local width, height, color_mode = image.width, image.height, image.colorMode
    local info = frame_index and image_info_cache[frame_index]
    if info and pixel_fingerprint and info.pixel_fingerprint == pixel_fingerprint
       and info.width == width and info.height == height and info.color_mode == color_mode then
      return info.is_blank and nil or info
    end

    local transparent_value = (color_mode == ColorMode.INDEXED) and image.spec.transparentColor or 0
    info = {
      pixel_fingerprint = pixel_fingerprint, width = width, height = height, color_mode = color_mode,
      transparent_value = transparent_value, grown_area_cache = {}, is_blank = true
    }

    local visible_area = image:shrinkBounds() -- Box around everything that isn't transparent
    if not visible_area.isEmpty then
      info.left, info.top = visible_area.x, visible_area.y
      info.right = visible_area.x + visible_area.width - 1
      info.bottom = visible_area.y + visible_area.height - 1
      info.is_blank = false
    end

    if frame_index and pixel_fingerprint then image_info_cache[frame_index] = info end
    return info.is_blank and nil or info
  end

  local function get_filled_pixels(info, image)
    if info.filled_pixels then return info.filled_pixels end
    local color_mode, pixel_color = info.color_mode, app.pixelColor
    local transparent_value, width = info.transparent_value, info.width
    local filled_pixels, filled_count = {}, 0

    for y = info.top, info.bottom do
      local row_start = y * width
      for x = info.left, info.right do
        local color = image:getPixel(x, y)
        local is_transparent
        if color_mode == ColorMode.RGB then is_transparent = pixel_color.rgbaA(color) == 0
        elseif color_mode == ColorMode.GRAY then is_transparent = pixel_color.grayaA(color) == 0
        else is_transparent = (color == transparent_value) end
        if not is_transparent then
          filled_pixels[row_start + x] = color
          filled_count = filled_count + 1
        end
      end
    end

    info.filled_pixels, info.filled_count = filled_pixels, filled_count
    return filled_pixels
  end

  local function get_grown_area(info, margin)
    local remembered = info.grown_area_cache[margin]
    if remembered then return remembered end

    local filled_pixels, width, height = info.filled_pixels, info.width, info.height
    local grown_sideways = {}
    for y = info.top, info.bottom do
      local row_start = y * width
      for x = info.left, info.right do
        if filled_pixels[row_start + x] then
          for shift = larger(-margin, -x), smaller(margin, width - 1 - x) do
            grown_sideways[row_start + x + shift] = true
          end
        end
      end
    end

    local grown_area = {}
    for key in pairs(grown_sideways) do
      local y, x = key // width, key % width
      for shift = larger(-margin, -y), smaller(margin, height - 1 - y) do
        grown_area[key + shift * width] = true
      end
    end

    info.grown_area_cache[margin] = grown_area
    return grown_area
  end

  -----------------------------------------------------------------------
  -- EFFECT: BOILING --
  -----------------------------------------------------------------------
  local gradient_x, gradient_y
  local function build_gradient_grid()
    gradient_x, gradient_y = {}, {}
    for i = 0, 65535 do
      local column, row = i & 255, i >> 8
      gradient_x[i] = random_from_numbers(column, row, 1) * 2 - 1
      gradient_y[i] = random_from_numbers(column, row, 2) * 2 - 1
    end
  end

  local function smooth_noise_at(x, y)
    local cell_x, cell_y = round_down(x), round_down(y)
    local from_left, from_top = x - cell_x, y - cell_y
    local from_right, from_bottom = from_left - 1, from_top - 1

    local ease_x = from_left * from_left * from_left * (6 * from_left * from_left - 15 * from_left + 10)
    local ease_y = from_top * from_top * from_top * (6 * from_top * from_top - 15 * from_top + 10)

    local left_column, right_column = cell_x & 255, (cell_x + 1) & 255
    local top_row, bottom_row = (cell_y & 255) << 8, ((cell_y + 1) & 255) << 8
    local top_left, top_right = top_row | left_column, top_row | right_column
    local bottom_left, bottom_right = bottom_row | left_column, bottom_row | right_column

    local influence_top_left = gradient_x[top_left] * from_left + gradient_y[top_left] * from_top
    local influence_bottom_left = gradient_x[bottom_left] * from_left + gradient_y[bottom_left] * from_bottom
    local influence_top_right = gradient_x[top_right] * from_right + gradient_y[top_right] * from_top
    local influence_bottom_right = gradient_x[bottom_right] * from_right + gradient_y[bottom_right] * from_bottom

    local blended_top = influence_top_left + (influence_top_right - influence_top_left) * ease_x
    local blended_bottom = influence_bottom_left + (influence_bottom_right - influence_bottom_left) * ease_x
    return blended_top + (blended_bottom - blended_top) * ease_y
  end

  function effect_boiling(image, context)
    local info = get_image_info(image, context.index)
    if not info then return image end
    local filled_pixels = get_filled_pixels(info, image)
    if info.filled_count == 0 then return image end
    if not gradient_x then build_gradient_grid() end

    local width, height = info.width, info.height
    local push_distance = blend(1, 3, context.intensity_ratio)
    local noise_scale = blend(1, 6, context.density_ratio) / smaller(context.sprite.width, context.sprite.height)
    local angle_range = push_distance * 4 * math.pi
    local edge_margin = round_up(push_distance)
    local nearby_area = get_grown_area(info, edge_margin)
    local block_size = larger(1, BOIL_BLOCK_SIZE)

    local frame_offset_x = random_from_numbers(context.index, 11, 5) * 1024
    local frame_offset_y = random_from_numbers(context.index, 12, 5) * 1024

    local result_image = Image(image.spec)
    result_image:clear()
    local first_column = larger(0, info.left - edge_margin)
    local last_column = smaller(width - 1, info.right + edge_margin)
    local first_row = larger(0, info.top - edge_margin)
    local last_row = smaller(height - 1, info.bottom + edge_margin)

    local cached_angles = {}
    for y = first_row, last_row do
      local row_start = y * width
      if block_size > 1 and (y - first_row) % block_size == 0 then cached_angles = {} end
      for x = first_column, last_column do
        if nearby_area[row_start + x] then
          local angle
          if block_size == 1 then
            angle = smooth_noise_at(noise_scale * (x + frame_offset_x), noise_scale * (y + frame_offset_y)) * angle_range
          else
            local block_column = x - (x - first_column) % block_size
            angle = cached_angles[block_column]
            if not angle then
              local block_row = y - (y - first_row) % block_size
              angle = smooth_noise_at(noise_scale * (block_column + frame_offset_x),
                                      noise_scale * (block_row + frame_offset_y)) * angle_range
              cached_angles[block_column] = angle
            end
          end

          local source_x = x + round_down(cosine(angle) * push_distance + 0.5)
          local source_y = y + round_down(sine(angle) * push_distance + 0.5)
          if source_x < 0 or source_x >= width or source_y < 0 or source_y >= height then
            source_x, source_y = x, y
          end
          local color = filled_pixels[source_y * width + source_x]
          if color then result_image:putPixel(x, y, color) end
        end
      end
    end
    return result_image
  end

  -----------------------------------------------------------------------
  -- EFFECT: NOISE --
  -----------------------------------------------------------------------
  local function get_distance_from_edge(info)
    if info.distance_from_edge then return info.distance_from_edge, info.deepest_distance end

    local filled_pixels, width = info.filled_pixels, info.width
    local left, top, right, bottom = info.left, info.top, info.right, info.bottom
    local distance_from_edge, deepest_distance = {}, 1

    for y = top, bottom do
      local row_start = y * width
      for x = left, right do
        distance_from_edge[row_start + x] = filled_pixels[row_start + x] and 1000000 or 0
      end
    end

    for y = top, bottom do
      local row_start = y * width
      for x = left, right do
        local key = row_start + x
        local distance = distance_from_edge[key]
        if distance > 0 then
          local distance_left = (x > left) and distance_from_edge[key - 1] or 0
          local distance_above = (y > top) and distance_from_edge[key - width] or 0
          distance_from_edge[key] = smaller(distance, distance_left + 1, distance_above + 1)
        end
      end
    end

    for y = bottom, top, -1 do
      local row_start = y * width
      for x = right, left, -1 do
        local key = row_start + x
        local distance = distance_from_edge[key]
        if distance > 0 then
          local distance_right = (x < right) and distance_from_edge[key + 1] or 0
          local distance_below = (y < bottom) and distance_from_edge[key + width] or 0
          distance = smaller(distance, distance_right + 1, distance_below + 1)
          distance_from_edge[key] = distance
          if distance > deepest_distance then deepest_distance = distance end
        end
      end
    end

    info.distance_from_edge, info.deepest_distance = distance_from_edge, deepest_distance
    return distance_from_edge, deepest_distance
  end

  function effect_noise(image, context)
    local info = get_image_info(image, context.index)
    if not info then return image end
    local filled_pixels = get_filled_pixels(info, image)
    if info.filled_count == 0 then return image end
    local distance_from_edge, deepest_distance = get_distance_from_edge(info)

    local chance_to_move = blend(0.10, 0.90, context.density_ratio)
    local biggest_shift = 1 + round_to_nearest(context.density_ratio * 2)
    local width, height = info.width, info.height
    local random_seed = context.index * 8
    local deepest_pixel_allowed = 1 + round_to_nearest((deepest_distance - 1) * context.intensity_ratio)
    local shift_choices = biggest_shift * 2 + 1

    -- Decide which pixels move and where they go (separate lists, one entry per moving pixel)
    local from_x, from_y, to_x, to_y, colors, move_count = {}, {}, {}, {}, {}, 0
    for y = info.top, info.bottom do
      local row_start = y * width
      for x = info.left, info.right do
        local distance = distance_from_edge[row_start + x]
        if distance > 0 and distance <= deepest_pixel_allowed
           and random_from_numbers(x, y, random_seed + 1) < chance_to_move then
          local shift_x = round_down(random_from_numbers(x, y, random_seed + 2) * shift_choices) - biggest_shift
          local shift_y = round_down(random_from_numbers(x, y, random_seed + 3) * shift_choices) - biggest_shift
          if shift_x == 0 and shift_y == 0 then
            shift_x = (random_from_numbers(x, y, random_seed + 4) < 0.5) and -1 or 1
          end
          move_count = move_count + 1
          from_x[move_count], from_y[move_count] = x, y
          to_x[move_count], to_y[move_count] = x + shift_x, y + shift_y
          colors[move_count] = filled_pixels[row_start + x]
        end
      end
    end

    local result_image = Image(image)
    local transparent_value = info.transparent_value
    for i = 1, move_count do result_image:putPixel(from_x[i], from_y[i], transparent_value) end -- Lift pixels
    for i = 1, move_count do -- Put them down in their new spot
      local new_x, new_y = to_x[i], to_y[i]
      if new_x >= 0 and new_y >= 0 and new_x < width and new_y < height then
        result_image:putPixel(new_x, new_y, colors[i])
      end
    end
    return result_image
  end

  -----------------------------------------------------------------------
  -- EFFECT: WAVE --
  -----------------------------------------------------------------------
  function effect_wave(image, context)
    local info = get_image_info(image, context.index)
    if not info then return image end

    local wave_length = blend(32, 8, context.density_ratio) -- Rows per full wave
    local wave_height = blend(1, 5, context.intensity_ratio) -- How many pixels it sways sideways
    local wave_start = (context.total <= 1) and math.pi / 2
                       or FULL_CIRCLE * (context.index - 1) / context.total + math.pi / 4 -- One full cycle across the frames

    local result_image = Image(image.spec)
    result_image:clear()
    local row_width = info.right - info.left + 1
    for y = info.top, info.bottom do
      local sideways_shift = round_to_nearest(wave_height * sine(FULL_CIRCLE * (y - info.top) / wave_length + wave_start))

      result_image:drawImage(Image(image, Rectangle(info.left, y, row_width, 1)),
                             Point(info.left + sideways_shift, y))
    end
    return result_image
  end
end

-----------------------------------------------------------------------
-- DYNAMIC UI --
-----------------------------------------------------------------------
local function keep_dialog_size(fn)
  local before = dlg.bounds
  fn()
  local after = dlg.bounds
  if after.x ~= before.x or after.y ~= before.y or after.width ~= before.width or after.height ~= before.height then
    dlg.bounds = Rectangle(before.x, before.y, before.width, before.height)
  end
end

local function sprite_is_open()
  if not sprite then return false end
  local ok, found = pcall(function()
    for _, s in ipairs(app.sprites) do
      if s == sprite then return true end
    end
    return false
  end)
  return ok and found
end

-- Layer name(s) of the current selection (shortened if too long)
local function layer_label()
  local name = selection and selection.name or "No layer"
  if #name > MAX_LABEL_LENGTH then name = name:sub(1, MAX_LABEL_LENGTH - 3) .. "..." end
  return name
end

-- Refreshes the labels and enables / disables the buttons
local function update_ui()
  if not dlg then return end
  local has_sprite = sprite_is_open()
  local can_play = has_sprite and frame_count >= MIN_PLAYABLE_FRAMES
  dlg:modify{ id="layer_name_label", text=layer_label() }
  dlg:modify{ id="frame_count_label", text=string.format("Frames selected: %d", frame_count) }
  dlg:modify{ id="play", enabled=can_play }
  dlg:modify{ id="previous", enabled=can_play }
  dlg:modify{ id="next", enabled=can_play }
  dlg:modify{ id="refresh_selection", enabled=has_sprite }
  dlg:modify{ id="apply", enabled=has_sprite and #MODIFIERS > 0 }
end

-- Show / hide everything under the playback row
local function apply_options_visibility()
  local visible = not collapsed
  local ids = {
    "refresh_selection", "apply",
    "option_intensity_label", "option_intensity",
    "option_density_label", "option_density",
    "option_animation_fps_label", "option_animation_fps",
  }
  if #MODIFIERS > 0 then
    ids[#ids + 1] = "option_effect_label"
    for _, modifier in ipairs(MODIFIERS) do ids[#ids + 1] = "option_effect_" .. modifier.id end
  end
  for _, id in ipairs(ids) do dlg:modify{ id=id, visible=visible } end
  dlg:modify{ id="collapse_toggle", text = collapsed and "Show Options" or "Hide Options" }
end

local function toggle_options()
  collapsed = not collapsed
  keep_dialog_size(apply_options_visibility)
end

-- Runs the selected modifier on a copy of every source frame (no effect if none is installed)
local function build_preview_cache()
  local modifier = MODIFIERS[effect_index]
  local first_error
  preview_images = {}

  for i, frame_number in ipairs(selection.frames) do
    local image = Image(source_images[i])
    if modifier then
      local ok, result = pcall(modifier.apply, image, {
        sprite = sprite, frame_number = frame_number, index = i, total = #selection.frames,
        intensity = intensity, density = density,
        intensity_ratio = (intensity - MIN_INTENSITY) / (MAX_INTENSITY - MIN_INTENSITY),
        density_ratio = (density - MIN_DENSITY) / (MAX_DENSITY - MIN_DENSITY)
      })
      if ok and result then
        image = result
      else
        first_error = first_error or (ok and "No image was returned." or tostring(result))
        image = Image(source_images[i]) -- Fall back to the unmodified frame
      end
    end
    preview_images[i] = image
  end

  if first_error then app.alert("The '" .. modifier.label .. "' effect failed: " .. first_error) end
end

-- Starts or stops playback. Stopping resets to the first frame and restores the controls
local function set_playing(playing)
  if playing and (is_playing or frame_count < MIN_PLAYABLE_FRAMES) then return end

  if playing then
    timer = timer or Timer{
      interval = 1.0 / animation_fps,
      ontick = function()
        if not sprite_is_open() then set_playing(false) return end

        -- Move to the next frame, looping back to the first
        frame_current = (frame_current + 1) % frame_count
        dlg:repaint()
      end
    }
    timer.interval = 1.0 / animation_fps
    timer:start()
  elseif timer then
    timer:stop()
  end

  is_playing = playing
  if not playing then frame_current = 0 end
  if dlg then
    keep_dialog_size(function()
      dlg:modify{ id="play", text = playing and "Stop" or "Play" }
      dlg:modify{ id="previous", visible = not playing }
      dlg:modify{ id="next", visible = not playing }
    end)
  end
end

-- Reads the layer(s) and frames selected in the timeline and rebuilds the caches.
-- Returns false (after an alert) if the selection can't be used, and the previous one is kept
local function load_selection()
  if not sprite_is_open() then app.alert("The sprite this player was opened with is no longer open!") return false end
  if app.activeSprite ~= sprite then app.alert("Switch back to the sprite this player was opened with!") return false end

  -- Frames: selected range, or the active frame if nothing is selected
  local range, frames, picked = app.range, {}, {}
  for _, frame in ipairs(range.frames) do
    frames[#frames + 1] = (type(frame) == "number") and frame or frame.frameNumber
  end
  if #frames == 0 then frames[1] = app.activeFrame.frameNumber end
  table.sort(frames)
  for i = 2, #frames do
    if frames[i] ~= frames[i - 1] + 1 then
      app.alert("Non-contiguous frame selections are not supported. Select a continuous range of frames!")
      return false
    end
  end

  -- Layers: selected layers, or the active layer if nothing is selected
  for _, layer in ipairs(range.layers) do picked[#picked + 1] = layer end
  if #picked == 0 and app.activeLayer then picked[1] = app.activeLayer end
  if #picked == 0 then app.alert("Select a layer first!") return false end

  -- Read the layer order (bottom to top) and gather every image layer inside the selection.
  -- Groups are expanded (children only if visible). The anchor is the top-most selected layer
  local layers, anchor, has_tilemap = {}, nil, false
  local function collect(list, inside)
    for _, layer in ipairs(list) do
      local is_picked = false
      for _, p in ipairs(picked) do if p == layer then is_picked = true end end

      if layer.isGroup then
        collect(layer.layers, inside or is_picked)
      elseif inside or is_picked then
        if layer.isTilemap then
          has_tilemap = true
        elseif is_picked or layer.isVisible then
          layers[#layers + 1] = layer
        end
      end
      if is_picked then anchor = layer end
    end
  end
  collect(sprite.layers, false)

  -- Disable tilemap layer support
  if has_tilemap then app.alert("This script currently does not support tilemap layers.") return false end
  if #layers == 0 then app.alert("No image layers found in the selection!") return false end

  local names = {}
  for _, layer in ipairs(picked) do names[#names + 1] = layer.name end

  if dlg then set_playing(false) end
  selection = { layers = layers, anchor = anchor or picked[#picked], frames = frames, name = table.concat(names, ", ") }

  -- Read original full-canvas image of the selected layers for every selected frame
  source_images = {}
  for i, frame_number in ipairs(frames) do
    local image = Image(sprite.spec)
    image:clear()
    for _, layer in ipairs(layers) do
      local cel = layer:cel(frame_number)
      if cel then
        image:drawImage(cel.image, cel.position, math.floor(cel.opacity * (layer.opacity or 255) / 255), layer.blendMode or BlendMode.NORMAL)
      end
    end
    source_images[i] = image
  end
  frame_count = #frames

  build_preview_cache()
  update_ui()
  if dlg then dlg:repaint() end
  return true
end

-----------------------------------------------------------------------
-- APPLY EFFECT AND CREATE NEW LAYER --
-----------------------------------------------------------------------
local function apply_effect()
  local modifier = MODIFIERS[effect_index]
  if not modifier then return end
  if not sprite_is_open() then app.alert("The sprite this player was opened with is no longer open!") return end

  set_playing(false)
   -- Create new layer above the source layer
  app.transaction("Apply " .. modifier.label, function()
    local new_layer = sprite:newLayer()
    new_layer.name = modifier.label
    pcall(function()
      new_layer.parent = selection.anchor.parent
      new_layer.stackIndex = selection.anchor.stackIndex + 1
    end)
    -- Set frame duration to FPS setting
    for i, frame_number in ipairs(selection.frames) do
      sprite:newCel(new_layer, frame_number, preview_images[i], Point(0, 0))
      sprite.frames[frame_number].duration = 1.0 / animation_fps -- Seconds. Aseprite stores whole milliseconds
    end
  end)

  dlg:close()
end

-----------------------------------------------------------------------
-- LAUNCH --
-----------------------------------------------------------------------
if not app.activeSprite then
  app.alert("No file found. Open an image in Aseprite first!")
  return
end

-- Lock the script to the active Aseprite document
sprite = app.activeSprite


if safe_mode and (sprite.width > SAFE_MODE_MAX_WIDTH or sprite.height > SAFE_MODE_MAX_HEIGHT) then
  app.alert("Safe-mode is currently on. You cannot run this script if the canvas is greater than 512x512px.")
  return
end

-- Read the selected layer(s) and frames
if not load_selection() then return end

-----------------------------------------------------------------------
-- DIALOG WINDOW --
-----------------------------------------------------------------------
dlg = Dialog("Boil Generator")

-- Double-click timer
click_timer = Timer{
  interval = double_click_time,
  ontick = function()
    click_pending = false
    click_timer:stop()
  end
}

-- CANVAS: preview, zoom (scroll wheel), pan (drag), reset pan (double-click)
dlg:canvas{
  id = "viewport",
  width = canvas_size,
  height = canvas_size,
  hexpand = true,
  vexpand = true,

  onpaint = function(ev)
    local gc = ev.context
    if not sprite_is_open() then set_playing(false) return end

    local image = preview_images[frame_current + 1]
    if not image then return end
    -- Adjust zoom to autofit image on startup
    if auto_fit_zoom then
      auto_fit_zoom = false
      zoom = math.min(gc.width / image.width, gc.height / image.height)
      zoom = math.max(min_zoom, math.min(max_zoom, zoom >= 1 and math.floor(zoom) or zoom))
    end

  -- Centered in the canvas, shifted by the pan offset, snapped to whole pixels
    local w, h = math.max(1, math.floor(image.width * zoom)), math.max(1, math.floor(image.height * zoom))
    gc:drawImage(image, image.bounds,
      Rectangle(math.floor((gc.width - w) / 2 + pan_x), math.floor((gc.height - h) / 2 + pan_y), w, h))
  end,

  onwheel = function(ev)
    -- Whole steps above 1x, halving / doubling below it (0.5x, 0.25x, ...)
    if ev.deltaY > 0 then zoom = (zoom < 1) and zoom * 2 or zoom + 1
    else zoom = (zoom <= 1) and zoom / 2 or zoom - 1 end
    zoom = math.min(max_zoom, math.max(min_zoom, zoom))
    dlg:repaint()
  end,

  onmousedown = function(ev)
    if ev.button ~= MouseButton.LEFT then return end

    if click_pending and math.abs(ev.x - click_x) <= 4 and math.abs(ev.y - click_y) <= 4 then
      click_pending, dragging = false, false -- Second click of a double-click
      click_timer:stop()
      pan_x, pan_y = 0, 0
      dlg:repaint()
      return
    end

    click_pending, click_x, click_y = true, ev.x, ev.y
    click_timer:start()
    dragging, drag_x, drag_y = true, ev.x, ev.y
  end,

  onmousemove = function(ev)
    if dragging then
      pan_x, pan_y = pan_x + (ev.x - drag_x), pan_y + (ev.y - drag_y)
      drag_x, drag_y = ev.x, ev.y
      dlg:repaint()
    end
  end,

  onmouseup = function() dragging = false end
}

-- LABELS, PLAYBACK CONTROLS, REFRESH + APPLY
dlg:newrow():label{ id="layer_name_label", text=layer_label() }
dlg:newrow():label{ id="frame_count_label", text=string.format("Frames selected: %d", frame_count) }

dlg:newrow()
:button{ id="previous", text="<", hexpand=false, onclick=function()
  keep_dialog_size(function() frame_current = (frame_current - 1) % frame_count dlg:repaint() end)
end }
:button{ id="play", text="Play", onclick=function()
  set_playing(not is_playing)
  if not is_playing then dlg:repaint() end -- Show the reset (first) frame
end }
:button{ id="next", text=">", hexpand=false, onclick=function()
  keep_dialog_size(function() frame_current = (frame_current + 1) % frame_count dlg:repaint() end)
end }
:button{ id="collapse_toggle", text="Hide Options", onclick=toggle_options }

dlg:newrow()
:button{ id="refresh_selection", text="Refresh Selection", onclick=function() keep_dialog_size(load_selection) end }
:button{ id="apply", text="Apply", onclick=apply_effect }

-- EFFECT: one radio button per registered effect
if #MODIFIERS > 0 then
  dlg:newrow():label{ id="option_effect_label", text="Effect:" }
  for i, modifier in ipairs(MODIFIERS) do
    dlg:radio{
      id = "option_effect_" .. modifier.id,
      text = modifier.label,
      selected = (i == effect_index),
      onclick = function()
        effect_index = i
        for j, other in ipairs(MODIFIERS) do -- Keep the radio buttons mutually exclusive
          dlg:modify{ id="option_effect_" .. other.id, selected=(j == i) }
        end
        build_preview_cache()
        dlg:repaint()
      end
    }
  end
end

-- OPTIONS
dlg:newrow():label{ id="option_intensity_label", text="Density" }
:slider{ id="option_intensity", min=MIN_INTENSITY, max=MAX_INTENSITY, value=intensity,
  onchange=function() intensity = dlg.data.option_intensity build_preview_cache() dlg:repaint() end }

dlg:newrow():label{ id="option_density_label", text="Intensity" }
:slider{ id="option_density", min=MIN_DENSITY, max=MAX_DENSITY, value=density,
  onchange=function() density = dlg.data.option_density build_preview_cache() dlg:repaint() end }

dlg:newrow():label{ id="option_animation_fps_label", text="Animation Speed (FPS)" }
:slider{ id="option_animation_fps", min=1, max=60, value=animation_fps, onchange=function()
  animation_fps = math.max(1, math.min(60, dlg.data.option_animation_fps))
  if timer and is_playing then
    timer:stop()
    timer.interval = 1.0 / animation_fps
    timer:start()
  end
end }

dlg:show{ wait=false, onclose=function()
  if timer then timer:stop() end
  if click_timer then click_timer:stop() end
  if listener then app.events:off(listener) end
end }

if collapsed then keep_dialog_size(apply_options_visibility) end
update_ui()

-- Disable Play, Refresh and Apply when the active document is closed
listener = app.events:on('sitechange', function()
  if not sprite_is_open() then set_playing(false) end
  update_ui()
  dlg:repaint()
end)