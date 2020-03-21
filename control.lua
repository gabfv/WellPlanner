require("mod-gui")
PriorityQueue = require("priority_queue")


function string:starts_with(prefix)
  return string.find(self, prefix) == 1
end

-- returns a string representation of a position
local function key(position)
    return math.floor(position.x) .. "," .. math.floor(position.y)
end

local function init()
  if not global.config then
    global.config = {
      well_planner_use_pipe_to_ground = true,
      well_planner_place_power_poles = true,      
    }
  end
end

function table.clone(org)
  local copy = {}
  for k, v in pairs(org) do
      copy[k] = v
  end
  return copy
end


local pump_neighbors = {
  {x = 1, y = -2, direction = defines.direction.north},
  {x = 2, y = -1, direction = defines.direction.east},
  {x = -1, y = 2, direction = defines.direction.south},
  {x = -2, y = 1, direction = defines.direction.west},  
}

local function makeNodesFromPatch(patch)
  local nodes = {}
  for i, n in ipairs(pump_neighbors) do
    local node = {
      patch = patch,
      position = {
        x = patch.position.x + n.x,
        y = patch.position.y + n.y,
      },
      direction = n.direction,
    }
    node.key = key(node.position)
    nodes[i] = node
  end

  return nodes
end

local function heuristicScore(goals, node)
  local score = math.huge
  for _, goal in ipairs(goals) do
    score = math.min(score, math.abs(goal.position.x - node.position.x) + math.abs(goal.position.y - node.position.y))
  end
  return score
end

local pipe_neighbors = {
  {x = 0, y = -1},
  {x = 1, y = 0},
  {x = 0, y = 1},
  {x = -1, y = 0},  
}


local function make_neighbors(parent)
  local nodes = {}
  for i, n in ipairs(pipe_neighbors) do
    local node = {
      parent = parent,
      position = {
        x = parent.position.x + n.x,
        y = parent.position.y + n.y,
      },
      g_score = parent.g_score + 1,
    }
    node.key = key(node.position)
    nodes[i] = node
  end
  return nodes
end

local function a_star(start_nodes, goal_nodes, blockers_map)
  local search_queue = PriorityQueue:new()
  local count = 0

  local all_nodes_map = start_nodes

  for _, node in ipairs(start_nodes) do
    if not blockers_map[node.key] then
      node.g_score = 0
      node.f_score = 0 + heuristicScore(goal_nodes, node)
      all_nodes_map[node.key] = node
      search_queue:put(node, node.f_score * 1000 + count)
      count = count + 1
    end
  end

  while not search_queue:empty() do
    local best = search_queue:pop()

    for _, n in ipairs(make_neighbors(best)) do
      if not blockers_map[n.key] then
        local o = all_nodes_map[n.key]
        if o == nil or n.g_score < o.g_score then
          local h = heuristicScore(goal_nodes, n)
          if h == 0 then
            for _, g in ipairs(goal_nodes) do
              if g.key == n.key then
                g.parent = n.parent
                return g
              end
            end 
            return n
          end
          n.f_score = n.g_score + h
          all_nodes_map[n.key] = n
          search_queue:put(n, n.f_score * 1000 + count)
          count = count + 1
        end
      end
    end
  end
  -- no path found
  return nil
end

local function min_pos(a, b)
  return {
    x = math.min(a.x, b.x),
    y = math.min(a.y, b.y)
  }
end

local function max_pos(a, b)
  return {
    x = math.max(a.x, b.x),
    y = math.max(a.y, b.y)
  }
end

local function dist_squared(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

local function log_object(o)
  log("\r" .. serpent.block(o))
end

local function add_point(work_zone, point)
  if work_zone.left_top == nil then
    work_zone.left_top = table.clone(point)
  else
    work_zone.left_top = min_pos(point, work_zone.left_top)
  end
  if work_zone.right_bottom == nil then
    work_zone.right_bottom = table.clone(point)
  else
    work_zone.right_bottom = max_pos(point, work_zone.right_bottom)
  end
end

local function expand_box(box, amount) 
  box.left_top.x = box.left_top.x - amount
  box.left_top.y = box.left_top.y - amount
  box.right_bottom.x = box.right_bottom.x + amount
  box.right_bottom.y = box.right_bottom.y + amount
end

local function place_ghost(state, prototype_name, position, direction)
  local args = {}
  args.name = "entity-ghost"
  args.inner_name = prototype_name
  args.position = position
  args.direction = direction
  args.force = state.force
  args.player = state.player
  args.raise_built = true
  state.surface.create_entity(args)	
end

local function distance_error(position_groups, position)
  local error = 0

  for _, pg in ipairs(position_groups) do
    for _, p in ipairs(pg) do
      error = error + dist_squared(p, position)
    end
  end
  return error
end

local function distance_error2(position_groups, position1, position2)
  local error1 = 0
  local error2 = 0

  for _, pg in pairs(position_groups) do
    for _, p in pairs(pg) do
      error1 = error1 + dist_squared(p, position1)
      error2 = error2 + dist_squared(p, position2)
    end
  end
  return error1, error2
end

-- find the min distance squared between two groups
local function error_between_groups(g1, g2)
  local error = math.huge
  local l1 = #g1
  local l2 = #g2
  for i = 1, l1 do
    p1 = g1[i]
    for j = 1, l2 do
      p2 = g2[j]
      local e = dist_squared(p1, p2)
      if e < error then
        error = e
      end
    end
  end
  return error
end

-- find the 2 closest poles in the 2 groups
local function find_closest_poles(g1, g2)
  local error = math.huge
  local l1 = #g1
  local l2 = #g2
  local out1, out2
  for i = 1, l1 do
    p1 = g1[i]
    for j = 1, l2 do
      p2 = g2[j]
      local e = dist_squared(p1, p2)
      if e < error then
        error = e
        out1 = p1
        out2 = p2
      end
    end
  end
  return out1, out2
end

-- fast merge 2 tables
local function fast_merge(t1, t2)
  local count = #t1
  local len = #t2
  for i = 1, len do
    t1[i+count] = t2[i]
  end
end

local function not_blocked(blockers_map, position, width, height) 
  local width_adjust = (width - 1) / 2
  local height_adjust = (height - 1) / 2

  local x1 = position.x - width_adjust
  local y1 = position.y - height_adjust

  for x = 0, width - 1 do
    local x2 = x1 + x
    for y = 0, height - 1 do
      local y2 = y1 + y
      if blockers_map[key({x = x2, y = y2})] then 
        return false
      end
    end
  end
  return true
end

local function connect_2_pole_groups(g1, g2, blockers_map, wire_range_squared, width, height)
  local p1, p2 = find_closest_poles(g1, g2)

  -- loop until we can merge the two groups or we fail to find a pole between them
  while true do
    local box = {}
    add_point(box, p1)
    add_point(box, p2)
    
    local best_score = 0
    local best_error = math.huge
    local best_pos
    for x = box.left_top.x, box.right_bottom.x do
      for y = box.left_top.y, box.right_bottom.y do
        local score = 0
        local pos = {x = x, y = y}
        if not_blocked(blockers_map, pos, width, height) then
          local ds1 = dist_squared(pos, p1)
          local ds2 = dist_squared(pos, p2)
          if ds1 <= wire_range_squared then
            score = score + 1
          end
          if ds2 <= wire_range_squared then
            score = score + 2
          end

          if score > best_score then
            best_score = score
            best_pos = pos
            best_error = math.huge
          elseif score == best_score then
            error = ds1 + ds2
            if error < best_error then
              best_error = error
              best_pos = pos
            end
          end
        end
      end
    end

    if best_score == 0 then
      -- failed to connect the groups
      return {g1, g2}
    elseif best_score == 1 then
      -- found a pole that fits in group 1
      local g3 = {best_pos}
      fast_merge(g3, g1)
      g1 = g3
      p1 = best_pos
    elseif best_score == 2 then
      -- found a pole that fits in group 2
      local g3 = {best_pos}
      fast_merge(g3, g2)
      g2 = g3
      p2 = best_pos
    elseif best_score == 3 then
      -- found a pole that joins both groups
      -- return a single merged group
      local g3 = {best_pos}
      fast_merge(g3, g1)    
      fast_merge(g3, g2)
      return {g3}    
    end
  end
end

-- pole_groups = connect_pole_groups(pole_groups, blockers_map)
local function connect_pole_groups(pole_groups, blockers_map, wire_range_squared, width, height)
  while true do
    if #pole_groups < 2 then
      return pole_groups
    elseif #pole_groups == 2 then
      return connect_2_pole_groups(pole_groups[1], pole_groups[2], blockers_map, wire_range_squared, width, height)
    end

    local error = math.huge
    local j = 0
    local pg1
    for i, pg in ipairs(pole_groups) do
      if i == 1 then
        pg1 = pg
      else
        local e = error_between_groups(pg1, pg)
        if e < error then
          error = e
          j = i
        end
      end
    end

    if j == 0 then
      -- this shouldn't happen
      return pole_groups
    end

    -- g2 will hold everything except pole_groups[1] and pole_groups[j]
    local g2 = {}
    local count = 0
    for i = 2, #pole_groups do
      if i ~= j then
        count = count + 1
        g2[count] = pole_groups[i]
      end
    end
    local new_groups = connect_2_pole_groups(pole_groups[1], pole_groups[j], blockers_map, wire_range_squared, width, height)
    fast_merge(g2, new_groups)
    pole_groups = g2
  end
end

-- blockers_map map of blocked squares
-- consumers - items that need power {position, size}
-- pole_prototype - the prototype of the power pole to use
local function place_power_poles(blockers_map, consumers, pole_prototype, work_zone, state)
  pole_groups = {}

  local width = math.ceil(pole_prototype.selection_box.right_bottom.x - pole_prototype.selection_box.left_top.x)
  local width_adjust = (width - 1) / 2
  local height = math.ceil(pole_prototype.selection_box.right_bottom.y - pole_prototype.selection_box.left_top.y)
  local height_adjust = (height - 1) / 2

  local wire_range = pole_prototype.max_wire_distance
  local wire_range_squared = wire_range * wire_range

  while #consumers > 0 do
    
    local best_score = 0
    for x = work_zone.left_top.x - width_adjust, work_zone.right_bottom.x + width_adjust do
      for y = work_zone.left_top.y - height_adjust, work_zone.right_bottom.y + height_adjust do
        local pos = {x = x, y = y}
        if not_blocked(blockers_map, pos, width, height) then
          local score = 0
          for _, c in ipairs(consumers) do
            local range = c.size + pole_prototype.supply_area_distance - 0.5
            if math.abs(c.position.x - x) < range then
              if math.abs(c.position.y - y) < range then
                score = score + 1
              end
            end
          end
          
          if score > best_score then
            best_score = score
            best_pos = pos
          else
            if score == best_score then
              e1, e2 = distance_error2(pole_groups, pos, best_pos)
              if e1 < e2 then
                best_pos = pos
              end
            end
          end
        end
      end
    end

    if best_score == 0 then
      break
    end
    
    local new_group = {best_pos}
    local new_groups = {new_group}
    
    for _, pg in ipairs(pole_groups) do
      local found = false
      for _, p in ipairs(pg) do
        if dist_squared(p, best_pos) <= wire_range_squared then
          found = true
          break
        end
      end
      if found then
        local j = #new_group
        for i, p in ipairs(pg) do
          new_group[i + j] = p
        end
      else
        table.insert(new_groups, pg)
      end
    end
    pole_groups = new_groups
    
    local new_consumers = {}
    for _, c in ipairs(consumers) do
      local found = false
      local range = c.size + pole_prototype.supply_area_distance - 0.5
      if math.abs(c.position.x - best_pos.x) < range then
        if math.abs(c.position.y - best_pos.y) < range then
          found = true
        end
      end
      if not found then
        table.insert(new_consumers, c)
      end
    end

    consumers = new_consumers
  end

  pole_groups = connect_pole_groups(pole_groups, blockers_map, wire_range_squared, width, height)

  for _, pg in ipairs(pole_groups) do
    for _, p in ipairs(pg) do
      place_ghost(state, pole_prototype.name, p)
    end
  end
  
end



local min_pipe_run = 2

local function on_selected_area(event, deconstruct_friendly)
  init()

  local player = game.players[event.player_index]
  local surface = player.surface
  local force = player.force
--	local conf = get_config(player)

  local state = {
    player = player,
    force = force,
    surface = surface,
  }

  local fluid_patches = {}

  -- find oil patches...
  work_zone = {}
  for i, entity in ipairs(event.entities) do
    -- ghost entities are not "valid"
    if entity.valid then
      p = entity.prototype
      if p.resource_category == "basic-fluid" then
        table.insert(fluid_patches, {position = entity.position})
        add_point(work_zone, entity.position)
      end	
    end	
  end
  
  if #fluid_patches == 0 then
    return
  end

  expand_box(work_zone, 3)

  -- Deconstruct anything in the area
  local da = {
    area = work_zone,
    force = force,
    player = player,
    skip_fog_of_war = true,
  }
  surface.deconstruct_area(da)


  if #fluid_patches == 1 then
    local patch = fluid_patches[1]
    place_ghost(state, "pumpjack", patch.position, defines.direction.north)
    return
  end

  local blockers_map = {}
  local min, max

  for i, patch in ipairs(fluid_patches) do
    if i == 1 then
      min = patch.position
      max = patch.position
    else
      min = min_pos(min, patch.position)
      max = max_pos(max, patch.position)
    end
    for x = -1, 1 do
      for y = -1, 1 do
        local position = {
          x = patch.position.x + x,
          y = patch.position.y + y,
        }
        blockers_map[key(position)] = true
      end
    end
  end

  -- dont build on water tiles
  local tiles = surface.find_tiles_filtered{
    area = work_zone,
    name = {     
      "water",
      "deepwater",
      "water-green",
      "deepwater-green",
      "water-shallow",
      "water-mud"
    }
  }
  for _, t in ipairs(tiles) do
    blockers_map[key(t.position)] = true
  end

  -- find the center of the patches
  local center = {
    x = (min.x + max.x) / 2,
    y = (min.y + max.y) / 2,
  }

  -- add the patches to a queue
  -- patches closest to the center go first
  local patch_queue = PriorityQueue:new()
  for i, patch in ipairs(fluid_patches) do
    patch_queue:put(patch, dist_squared(center, patch.position))
  end

  local goals
  local starts
    
  local i = 0

  local pipes_to_place = {}
  while not patch_queue:empty() do
    i = i + 1
    local patch = patch_queue:pop()

    if i == 1 then
      goals = makeNodesFromPatch(patch)
    else
      starts = makeNodesFromPatch(patch)
      local node = a_star(starts, goals, blockers_map)

      if i == 2 then
        goals = {}
      end

      while node do
        pipes_to_place[key(node.position)] = node
        
        if node.patch then
          place_ghost(state, "pumpjack", node.patch.position, node.direction)

          node.patch = nil

          if node.direction == defines.direction.north or node.direction == defines.direction.south then 
            node.vertical_connection = true
          else
            node.horizontal_connection = true
          end

        end

        table.insert(goals, node)

        node = node.parent
      end      
    end
  end

  if global.config.well_planner_use_pipe_to_ground == true then
  -- convert to undergropund pipes
    pipe_zone = {}
    for k, node in pairs(pipes_to_place) do
      add_point(pipe_zone, node.position)
    end

    local left = math.floor(pipe_zone.left_top.x)
    local top = math.floor(pipe_zone.left_top.y)
    local right = math.floor(pipe_zone.right_bottom.x)
    local bottom = math.floor(pipe_zone.right_bottom.y)

    local count = 0

    local pipes_to_delete = {}
    local pipes_to_ground = {}

    -- replace east-west runs of pipe with pipe-to-ground
    for row = top, bottom do
      for col = left, right + 1 do
        local good = false
        local pipe = pipes_to_place[col .. "," .. row]
        if pipe then
          if not pipe.vertical_connection then
            if not (pipes_to_place[col .. "," .. (row - 1)] or pipes_to_place[col .. "," .. (row + 1)]) then
              good = true
            end
          end
        end

        if good then
          count = count + 1
        else
          if count >= min_pipe_run then
            for i = 1, count do
              table.insert(pipes_to_delete, (col - i) .. "," .. row)
            end
            local segments = math.floor((count + 10) / 11)
            for segment = 0, segments - 1 do
              local segment_start = math.floor(count * segment / segments)
              local segment_end = math.floor(count * (segment + 1) / segments) - 1

              local pos1 = {x = col - segment_start - 0.5, y = row + 0.5}
              place_ghost(state, "pipe-to-ground", pos1, defines.direction.east)
              table.insert(pipes_to_ground, key(pos1))

              local pos2 = {x = col - segment_end - 0.5, y = row + 0.5}
              place_ghost(state, "pipe-to-ground", pos2, defines.direction.west)
              table.insert(pipes_to_ground, key(pos2))
            end
          end
          count = 0
        end
      end
    end

    -- replace north-south runs of pipe with pipe-to-ground
    for col = left, right do
      for row = top, bottom + 1 do
      local good = false
        local pipe = pipes_to_place[col .. "," .. row]
        if pipe then
          if not pipe.horizontal_connection then
            if not (pipes_to_place[(col - 1) .. "," .. row] or pipes_to_place[(col + 1) .. "," .. row]) then
              good = true
            end
          end
        end

        if good then
          count = count + 1
        else
          if count >= min_pipe_run then
            for i = 1, count do
              table.insert(pipes_to_delete, col .. "," .. (row - i))
            end
            local segments = math.floor((count + 10) / 11)
            for segment = 0, segments - 1 do
              local segment_start = math.floor(count * segment / segments)
              local segment_end = math.floor(count * (segment + 1) / segments) - 1

              local pos1 = {x = col + 0.5, y = row - segment_start - 0.5}
              place_ghost(state, "pipe-to-ground", pos1, defines.direction.south)
              table.insert(pipes_to_ground, key(pos1))
              
              local pos2 = {x = col + 0.5, y = row - segment_end - 0.5}
              place_ghost(state, "pipe-to-ground", pos2, defines.direction.north)
              table.insert(pipes_to_ground, key(pos2))
            end
          end
          count = 0
        end
      end
    end

    -- remove the pipes
    for _, v in ipairs(pipes_to_delete) do
      pipes_to_place[v] = nil
    end

    for _, key in ipairs(pipes_to_ground) do
      blockers_map[key] = true
    end
  end

  -- connect with pipes
  for k, node in pairs(pipes_to_place) do
    place_ghost(state, "pipe", node.position)
    blockers_map[node.key] = true
  end

  -- power the area
  local consumers = {}
  for i, p in ipairs(fluid_patches) do
    table.insert(consumers, {position = p.position, size = 1.5})
  end

  if global.config.well_planner_place_power_poles then
    local ppt = global.config.well_planner_power_pole_type
    if ppt == nil then
      ppt = "small-electric-pole"
    end
    local power_poles = game.get_filtered_entity_prototypes({{filter = "type", type = "electric-pole"}, {filter = "flag", flag = "player-creation", mode = "and"}})
    local power_pole_proptotype = power_poles[ppt]

    if power_pole_proptotype == nil then
      for k,v in pairs(power_poles) do
        power_pole_proptotype = v
        global.config.well_planner_power_pole_type = k
        break
      end
    end

    place_power_poles(blockers_map, consumers, power_pole_proptotype, work_zone, state)
  end
end

function gui_open_close_frame(player)

  init()

  local flow = player.gui.center

  local frame = flow.well_planner_config_frame

  -- if the fram exists destropy it and return
  if frame then
    frame.destroy()
    return
  end

  -- Now we can build the GUI.
  frame = flow.add{
    type = "frame",
    name = "well_planner_config_frame",
    caption = {"well-planner.config-frame-title"},
    direction = "vertical"
  }

  frame.add(
    {
      type = "checkbox",
      name = "well_planner_use_pipe_to_ground",
      caption = {"well-planner.use_pipe_to_ground"},
      state = global.config.well_planner_use_pipe_to_ground == true,
      tooltip = {"well-planner.use_pipe_to_ground_tooltip"},
    }
  )
  frame.add(
    {
      type = "checkbox",
      name = "well_planner_place_power_poles",
      caption = {"well-planner.place_power_poles"},
      state = global.config.well_planner_place_power_poles == true,
      tooltip = {"well-planner.place_power_poles_tooltip"},
    }
  )

  local pole_flow = frame.add(
    {
      type = "flow",
      name = "well_planner_pole_flow",
      direction = "horizontal",
      enabled = global.config.well_planner_place_power_poles == true,
    }
  )

  local power_poles = game.get_filtered_entity_prototypes({{filter = "type", type = "electric-pole"}, {filter = "flag", flag = "player-creation", mode = "and"}})

  local ppt = global.config.well_planner_power_pole_type

  for entity_id, ppp in pairs(power_poles) do
    if ppt == nil then
      ppt = entity_id
    end

    local button_name = "well_planner_power_pole_type" .. "_" .. entity_id
    local style = "CGUI_logistic_slot_button"
    if ppt == entity_id then
      style = "CGUI_yellow_logistic_slot_button"
    end
    pole_flow.add (
      {
        name = button_name,
        type = "sprite-button",
        sprite = "entity/" .. entity_id,
        style = style,
      }
    )  
  end

  frame.add(
    {
      type = "button",
      name = "well_planner_close_button",
      caption = {"well-planner.close_button"},
    }
  )

end

local function on_mod_item_opened(event)
  local player = game.players[event.player_index]
  gui_open_close_frame(player)
end

script.on_event(
  defines.events.on_gui_click,
  function(event)
    local name = event.element.name
    if name == "well_planner_close_button" then
      local player = game.players[event.player_index]
      gui_open_close_frame(player)    
    elseif name:starts_with("well_planner_power_pole_type") then
      for _, v in pairs(event.element.parent.children) do
        v.style = "CGUI_logistic_slot_button"
      end
      event.element.style = "CGUI_yellow_logistic_slot_button"
      local ppt = name:sub(string.len("well_planner_power_pole_type") + 2)
      global.config.well_planner_power_pole_type = ppt
    end
  end
)

script.on_event(
  defines.events.on_gui_checked_state_changed,
  function(event)
    if event.element.name:starts_with("well_planner_") then
      global.config[event.element.name] = event.element.state
      event.element.parent.well_planner_pole_flow.enabled = global.config.well_planner_place_power_poles == true
    end
  end
)

script.on_event(
  defines.events.on_mod_item_opened,
  function(event)
    if event.item.name == "well-planner" then
      on_mod_item_opened(event)
    end
  end
)

script.on_event(
  defines.events.on_player_selected_area,
  function(event)
    if event.item == "well-planner" then
      on_selected_area(event)
    end
  end
)

script.on_event(
  defines.events.on_player_alt_selected_area,
  function(event)
    if event.item == "well-planner" then
      on_selected_area(event, true)
    end
  end
)

