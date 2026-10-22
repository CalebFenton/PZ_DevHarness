import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;

/**
 * The game queues a task per tile depth map at a lower priority than textures and models, and each
 * task holds its mod's TileDepthTextures for its whole load. So the maps load one at a time, on one
 * busy asset loader thread while the others wait for the lock, after every texture and animation,
 * and the loading screen waits for them once the world is ready. This runs the game's own tasks on
 * a thread of its own as soon as they are queued, before the world starts loading; the queued
 * tasks then find their maps loaded and return at once.
 *
 * TileDepthTextureManager.init queues them in GameWindow.enter, before the state machine shows its
 * first state, so this waits for that state rather than touching the class before the game has.
 */
final class DepthMaps {
    private static final long POLL_MS = 20;

    private DepthMaps() {
    }

    static void preloadOnceQueued() {
        Thread thread = new Thread(DepthMaps::preloadOnceMenuShows, "DepthMaps");
        thread.setDaemon(true); // never holds the JVM open after the game quits
        thread.start();
    }

    private static void preloadOnceMenuShows() {
        try {
            Field states = Class.forName("zombie.GameWindow").getField("states");
            Field current = Class.forName("zombie.gameStates.GameStateMachine").getField("current");
            while (current.get(states.get(null)) == null) {
                Thread.sleep(POLL_MS);
            }
            preload();
        } catch (Exception e) {
            // Only slower: the queued tasks load what this didn't.
            System.out.println("PZHarness: couldn't preload depth maps: " + e);
        }
    }

    private static void preload() throws Exception {
        Object manager = Class.forName("zombie.tileDepth.TileDepthTextureManager").getMethod("getInstance").invoke(null);
        List<?> mods = new ArrayList<Object>((List<?>) accessible(manager.getClass().getDeclaredField("modData")).get(manager));
        Constructor<?> newTask = Class.forName("zombie.tileDepth.TileDepthTextures$LoadTask").getDeclaredConstructor(
                Class.forName("zombie.tileDepth.TileDepthTextures"), Path.class, Class.forName("zombie.fileSystem.FileSystem"));
        newTask.setAccessible(true);
        Object fileSystem = Class.forName("zombie.GameWindow").getField("fileSystem").get(null);
        long start = System.currentTimeMillis();
        int loaded = 0;
        for (Object mod : mods) {
            Object textures = accessible(mod.getClass().getDeclaredField("textures")).get(mod);
            String media = (String) accessible(textures.getClass().getDeclaredField("mediaAbsPath")).get(textures);
            File[] files = new File(media, "depthmaps").listFiles();
            if (files == null) {
                continue;
            }
            for (File file : files) {
                // The files TileDepthTextures.loadDepthTextureImages queues a task for.
                String name = file.getName();
                if (!file.isFile() || !name.startsWith("DEPTH_") || !name.endsWith(".png")
                        || name.equalsIgnoreCase("DEPTH_whole_tile.png") || name.equalsIgnoreCase("DEPTH_preset_depthmaps_01.png")) {
                    continue;
                }
                // Its done() is left to the queued task, which counts the maps still loading.
                ((Callable<?>) newTask.newInstance(textures, file.toPath(), fileSystem)).call();
                loaded++;
            }
        }
        System.out.println("PZHarness: preloaded " + loaded + " depth maps in " + (System.currentTimeMillis() - start) + " ms");
    }

    private static Field accessible(Field field) {
        field.setAccessible(true);
        return field;
    }
}
