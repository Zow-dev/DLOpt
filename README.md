# DLOpt 1.4.0 - Days Later Optimizer

A small client-side performance tweak for **low-end PCs**.

> **For Days Later Server players only.**
> DLOpt is made for the Days Later server. It is not tested or supported on other servers or in single player.
> Nothing is installed on the server. This only changes your own game.

## What it does

1. **Smaller chunk grid (the main thing).**
   The game decides how many map chunks to keep loaded around you from your screen size. At 1080p that is up to 19x19 = 361 chunks.
   Lighting, chunk baking and chunk loading all get more expensive as that grid grows, and this is what hurts low-end PCs.
   DLOpt caps the grid at **11x11 = 121 chunks** by default. It never makes the grid bigger than the game would pick on its own.
2. **Gentler chunk loading (new in 1.1.0).**
   While you move, the game finishes loading a few chunks every frame. DLOpt lowers that number (default: about 3 chunks per frame instead of about 4)
   so the load is spread over more frames and lag spikes are smaller.
3. **Lower lighting thread priority (new in 1.1.0).**
   The lighting thread runs at normal priority and competes with the game on PCs with few CPU cores. DLOpt sets it one step lower.
4. **G1 garbage collector.**
   The installer makes G1 the only garbage collector in the game launcher file, so the JVM does not use another one.
   It does not change the game's memory (heap) setting.
5. **Logging.**
   DLOpt writes a few `[DLOpt]` lines to `console.txt` so you can check that it is active.
6. **Optional frame-time log (new in 1.2.0, off by default).**
   Measures your frame times so you can see if DLOpt helps on your PC. See "Measuring" below.
7. **Fewer mip levels for chunk textures (new in 1.3.0).**
   The game builds a full chain of 11 mip levels for every baked chunk texture. DLOpt builds only 3 by default.
   This is a small saving (fewer GPU calls per bake), so check it with the frame log. Set `bakeMipLevels=11` for vanilla.

8. **Zombie LOD (new in 1.4.0).**
   The game already updates far objects less often (every few frames) at 30, 60 and 80 tiles, and when FPS is low.
   DLOpt adds one more step for zombies past `zombieLodTiles` (default 12) and another past twice that, but only while your
   average FPS is under `zombieLodFpsBelow` (default 50). Far zombies are simulated less in hordes, so the game thread has less work.
   This is client side only (the game does not do it on a server). Set `zombieLodTiles=0` for vanilla.

## What it does not do

- It does not change the game files (`projectzomboid.jar` is untouched) and does not touch your saves or mods.
- It does not change graphics settings or add any in-game menu.
- It does not need anything installed on the server.

## Trade-offs

- **Smaller loaded area.** The map kept loaded around you is about 88 tiles wide instead of up to 152 at 1080p.
  Notes from the PZ Optimization project say 9x9 still covers a 1080p screen at the widest zoom, but we have not checked this ourselves.
  On a bigger screen you may see the edge of the loaded map.
- **Online.** The server still runs the world; DLOpt only changes what your own game keeps loaded.
  The server treats any grid smaller than 12 as 12 (the game also does this for small windows), so this is a known case, but report anything odd to the staff.
- **Far zoom-out.** With fewer mip levels, the map can look slightly shimmery when zoomed out far. Set `bakeMipLevels=11` if you notice it.
- **Map can appear later.** With gentler chunk loading, new map areas can show up a little later when you drive fast.
  If you see this, set `chunkLoadPerFrame=3`.

If you have a strong PC you do not need DLOpt.

## Install

1. Close Project Zomboid.
2. Extract this zip anywhere.
3. Double click `Install.bat`.
4. Start the game from Steam as usual.

## Uninstall

Double click `Uninstall.bat`. It removes the DLOpt agent and files and leaves every other launcher setting as it is (including the G1 flag and other mods' settings). To get the vanilla launcher file back, use Steam > Properties > Installed Files > Verify integrity of game files.

## If the game does not start

Run `Uninstall.bat`, then tell the Days Later staff what happened.

## Safety checks

`Install.bat`:

- finds the game folder through Steam (or asks you for it)
- refuses to run while the game is open
- refuses if the game's bundled Java is older than 25
- refuses if this DLOpt version does not match the game build (the code it patches is missing)
- makes a backup of `ProjectZomboid64.json` before changing it, and checks the result is valid before saving

At runtime, every patch checks the exact game code first. If it does not look as DLOpt expects, that patch is skipped and the game runs stock for that part.

## Settings

`dlopt.properties` is in the game folder.

| Key | Default | Vanilla | Meaning |
|---|---|---|---|
| `enabled` | `true` | - | `false` = the game runs fully stock |
| `chunkGridWidth` | `11` | up to 19 | Max chunk grid, odd number 5-19. `9` = smallest, `11` default, `13` best for driving |
| `chunkLoadPerFrame` | `2` | `3` | Chunks finished per frame while moving (1-8). Lower = smaller spikes, map can appear later |
| `lightingThreadPriority` | `4` | `5` | Lighting thread priority (1-10) |
| `bakeMipLevels` | `3` | `11` | Mip levels built per baked chunk texture (1-11). If the key is missing, 3 is used |
| `zombieLodTiles` | `12` | `0` | Distance (tiles) of the first extra zombie LOD step. `0` = off. Each next step is at 2x |
| `zombieLodSteps` | `2` | - | Extra steps (1-4) |
| `zombieLodFpsBelow` | `50` | - | Zombie LOD only while average FPS is below this |
| `frameLog` | `false` | - | `true` = write frame-time stats (see Measuring). With `enabled=false` it logs the game without the DLOpt game patches |
| `frameLogIntervalSec` | `30` | - | Seconds of play per summary (5-300) |
| `jvmPreset` | `g1` | - | Installer only. `off` = do not touch GC flags. Verify the game files in Steam, then run `Install.bat` after changing it |

Changes apply the next time you start the game (except `jvmPreset`).
To get the vanilla behaviour of one setting, set it to its vanilla value.

## Measuring (optional)

To check if DLOpt really helps on your PC:

1. In `dlopt.properties` set `frameLog=true`.
2. Start the game and do the same thing for 2-3 minutes each time (for example walk through the same town, then drive the same road).
3. Every 30 seconds DLOpt writes one line to `console.txt` and one row to `dlopt-frames.csv` in the game folder:
   - `fps` = average frames per second
   - `p95` / `p99` = how slow the slowest 5% / 1% of frames are (lower is better)
   - `>25ms` = share of frames slower than 25 ms (lower is better)
   - `rep60` = approximate share of 60 Hz screen refreshes that showed the previous frame again (lower is better, 0 = smooth 60)
   - `cfg` = the settings used, for example `g9-c1-p4` = grid 9, chunk load 1, lighting priority 4
4. Ignore the first lines (menu and loading screens). Compare runs that use the same route.
5. To compare with the game patches off, set `enabled=false` (the frame log keeps running, `mode=stock`), restart, and repeat the same route.
   The G1 setting from the installer stays on. For a fully stock baseline, verify the game files in Steam, set `jvmPreset=off`, run `Install.bat`, then set `enabled=false`.
6. Send `dlopt-frames.csv` to the Days Later staff.

Set `frameLog` back to `false` when you are done.

## Notes

- Run `Install.bat` again after Steam updates or verifies the game files. If it says the build is not supported, do not install; wait for a new DLOpt version.
- To check it works, open `console.txt` (in your Zomboid folder) and look for lines starting with `[DLOpt]`.
  You should also see `bake mip levels in effect: 3 (vanilla 11)` after you enter a world.
  You should see `patched MovingObjectUpdateScheduler.getUpdateSchedulerSimulationLevelForObject() (zombie LOD)` and `zombie LOD active ...` once a far zombie is lowered, `chunkGridWidth in effect: 11`, `patched IsoChunkMap.updateInternal()`, `patched LightingThread.create()` and a JVM line with `gc = G1 ...`.
