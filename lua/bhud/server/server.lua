--------------------------
--  RESTRICTION SYSTEM  --
--------------------------

util.AddNetworkString( "bhud_restrictions" )

-- Load restrictions
if file.Exists( "bhud_settings.txt", "DATA" ) then
	bhud.restrictions = util.JSONToTable( file.Read( "bhud_settings.txt", "DATA" ) )
else
	file.Write( "bhud_settings.txt", util.TableToJSON( { minimap = false, hovernames = false } ) )
	bhud.restrictions = { minimap = false, hovernames = false }
end

-- Send restrictions to clients
local function send_res( ply )

	net.Start( "bhud_restrictions" )
		net.WriteTable( bhud.restrictions )
	net.Send( ply )

end
hook.Add( "PlayerAuthed", "bhud_player_authed", send_res )

-- Change restrictions
local function change_res( ply, cmd, args )

	if cmd != "bhud_restrict" then return end

	local s, r = args[1], tobool( args[2] )

	if bhud.restrictions[s] == nil then
		print( "[bhud-Restrictions]: The setting '" .. s .. "' doesn't exist. Please use something else!" )
		return
	end

	bhud.restrictions[s] = r
	file.Write( "bhud_settings.txt", util.TableToJSON( bhud.restrictions ) )

	print( "[bhud-Restrictions]: Changed " .. s .. "-restriction to '" .. tostring( r ) .. "'!" )

	net.Start( "bhud_restrictions" )
		net.WriteTable( bhud.restrictions )
	net.Broadcast()

end
concommand.Add( "bhud_restrict", change_res )



-----------------------------
--  MINIMAP GUNFIRE TRACK  --
-----------------------------

util.AddNetworkString( "bhud_gunfire" )

-- Currently-visible-due-to-firing players. Keyed by player -> true.
bhud.firing = bhud.firing or {}

-- Tell everyone a player has started/stopped being minimap-visible due to gunfire
local function bhud_send_gunfire( ply, firing )

	net.Start( "bhud_gunfire" )
		net.WriteEntity( ply )
		net.WriteBool( firing )
	net.Broadcast()

end

-- Called once per shot. Players with the "sci_passive_stealth" passive never show up
-- from gunfire; everyone else shows up immediately when they shoot.
local function bhud_register_shot( ply )

	if !IsValid( ply ) or !ply:IsPlayer() then return end

	if ply:HavePassive( "sci_passive_stealth" ) then

		-- Stealthed: make sure they're not lingering as visible from an earlier shot
		if bhud.firing[ ply ] then
			bhud.firing[ ply ] = nil
			bhud_send_gunfire( ply, false )
		end

	else

		if !bhud.firing[ ply ] then
			bhud.firing[ ply ] = true
			bhud_send_gunfire( ply, true )
		end

	end

end

-- Covers hitscan weapons (pistols, rifles, SMGs, shotguns, etc.) - fires once per bullet
hook.Add( "EntityFireBullets", "bhud_gunfire_bullets", function( ply, data )
	bhud_register_shot( ply )
end )

-- Covers projectile-based weapons (RPG, grenades, crossbow, etc.) which don't
-- trigger EntityFireBullets. Not every gamemode/weapon base fires this hook,
-- but it's a reasonable best-effort catch for the common SWEP base case.
hook.Add( "PlayerFireProjectile", "bhud_gunfire_projectile", function( ply, ent )
	bhud_register_shot( ply )
end )

-- Clean up on disconnect so the table doesn't hold stale entities
hook.Add( "PlayerDisconnected", "bhud_gunfire_cleanup", function( ply )
	bhud.firing[ ply ] = nil
end )

-- Sync current firing-state to players as they join, so their minimap starts accurate
-- instead of assuming nobody is firing
hook.Add( "PlayerAuthed", "bhud_gunfire_sync", function( ply )

	for firer in pairs( bhud.firing ) do
		if IsValid( firer ) then
			net.Start( "bhud_gunfire" )
				net.WriteEntity( firer )
				net.WriteBool( true )
			net.Send( ply )
		end
	end

end )



----------------------
--  SQUAD TRACKING  --
----------------------

-- SquadMenu / GetSquadID / GetSquad / GetActiveMembers are serverside-only, so squad
-- membership has to be resolved here and networked down to each client individually
-- (a player should only know who their OWN squadmates are).

util.AddNetworkString( "bhud_squadmates" )

bhud.squadmates = bhud.squadmates or {} -- [ply] = { [squadmate] = true, ... }

-- Send `ply` their current squadmate list
local function bhud_send_squadmates( ply )

	local mates = bhud.squadmates[ ply ] or {}
	local list = {}
	for mate in pairs( mates ) do
		if IsValid( mate ) then list[ #list + 1 ] = mate end
	end

	net.Start( "bhud_squadmates" )
		net.WriteTable( list )
	net.Send( ply )

end

-- Returns the active members of ply's squad as a set (excluding ply itself), or {} if
-- ply isn't in a squad / SquadMenu isn't available.
local function bhud_get_squadmates( ply )

	if !SquadMenu or !IsValid( ply ) then return {} end

	local id = ply.GetSquadID and ply:GetSquadID()
	if !id or id == 0 then return {} end

	local squad = SquadMenu:GetSquad( id )
	if !squad then return {} end

	local members = squad:GetActiveMembers()
	if !members then return {} end

	local set = {}
	for _, member in pairs( members ) do
		if IsValid( member ) and member != ply then
			set[ member ] = true
		end
	end

	return set

end

-- Compares two membership sets for equality
local function bhud_sets_equal( a, b )

	for k in pairs( a ) do
		if !b[k] then return false end
	end
	for k in pairs( b ) do
		if !a[k] then return false end
	end
	return true

end

-- Poll squad membership and push updates only when a player's squadmate list actually
-- changes, to avoid spamming net messages every tick.
timer.Create( "bhud_squad_poll", 1, 0, function()

	for _, ply in ipairs( player.GetAll() ) do

		local current = bhud_get_squadmates( ply )
		local previous = bhud.squadmates[ ply ] or {}

		if !bhud_sets_equal( current, previous ) then
			bhud.squadmates[ ply ] = current
			bhud_send_squadmates( ply )
		end

	end

end )

-- Send accurate squadmate info as soon as a player joins
hook.Add( "PlayerAuthed", "bhud_squadmates_sync", function( ply )

	bhud.squadmates[ ply ] = bhud_get_squadmates( ply )
	bhud_send_squadmates( ply )

end )

hook.Add( "PlayerDisconnected", "bhud_squadmates_cleanup", function( ply )
	bhud.squadmates[ ply ] = nil
end )

-----------------------
--  DEBUG: FORCE JOIN --
-----------------------

-- Usage (server console / rcon):  bhud_force_squad_join Bot07 paloma
-- Forces the first player into the second player's squad, ignoring the member limit.
concommand.Add( "bhud_force_squad_join", function( ply, cmd, args )

	if !SquadMenu then
		print( "[bhud-Debug]: SquadMenu isn't loaded." )
		return
	end

	local targetName, hostName = args[1], args[2]
	if !targetName or !hostName then
		print( "[bhud-Debug]: Usage: bhud_force_squad_join <target> <squad_owner>" )
		return
	end

	local target = player.GetByName and player.GetByName( targetName )
	local host = player.GetByName and player.GetByName( hostName )

	-- Fallback in case player.GetByName isn't available: manual partial-name match
	if !IsValid( target ) or !IsValid( host ) then
		for _, p in ipairs( player.GetAll() ) do
			if !IsValid( target ) and string.find( string.lower( p:Nick() ), string.lower( targetName ), 1, true ) then
				target = p
			end
			if !IsValid( host ) and string.find( string.lower( p:Nick() ), string.lower( hostName ), 1, true ) then
				host = p
			end
		end
	end

	if !IsValid( target ) then
		print( "[bhud-Debug]: Couldn't find player '" .. targetName .. "'." )
		return
	end

	if !IsValid( host ) then
		print( "[bhud-Debug]: Couldn't find player '" .. hostName .. "'." )
		return
	end

	local hostSquadId = host:GetSquadID()
	if !hostSquadId or hostSquadId == 0 then
		print( "[bhud-Debug]: '" .. host:Nick() .. "' isn't in a squad." )
		return
	end

	local squad = SquadMenu:GetSquad( hostSquadId )
	if !squad then
		print( "[bhud-Debug]: Couldn't resolve squad #" .. hostSquadId .. "." )
		return
	end

	squad:AddMember( target, true ) -- true = ignoreLimit, for debug purposes

	print( "[bhud-Debug]: Forced '" .. target:Nick() .. "' into '" .. host:Nick() .. "'s squad (#" .. hostSquadId .. ")." )

end, nil, "Force a player into another player's squad. Usage: bhud_force_squad_join <target> <squad_owner>" )
