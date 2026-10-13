import java.lang.reflect.Field;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Starts the game client and presses "Click to start" whenever the loading screen shows it, so
 * the unattended runs of bin/run-client.sh (--test and the mod's own modes) need no one at the
 * computer. It also gives the game's asset loader more threads, which shortens loading.
 *
 * GameLoadingState.update() continues only after a real left click, a joypad A press, or its
 * private forceDone flag, and Lua can reach none of them, so this sets forceDone. The game runs its
 * loop on a thread named "MainThread", created by GameWindow.InitGameThread(). This waits for that
 * thread before touching GameWindow, because reading a static field of a class that isn't
 * initialized yet would initialize it here, out of the game's startup order.
 */
public class ClickToStart {
    private static final long POLL_MS = 500;

    public static void main(String[] args) throws Exception {
        Thread clicker = new Thread(ClickToStart::clickWhenAsked, "ClickToStart");
        clicker.setDaemon(true);
        clicker.start();
        Class.forName("zombie.gameStates.MainScreenState").getMethod("main", String[].class).invoke(null, (Object) args);
    }

    /**
     * FileSystemImpl loads textures, meshes, animations and depth maps on a pool of at most 4
     * threads, and the loading screen waits for all of them: about 8 of a run's seconds, with all
     * 4 threads busy throughout. Tasks it has already handed to the old pool finish there; the
     * game itself keeps at most 16 tasks in flight, so more threads than that would idle.
     */
    private static void widenAssetLoading() {
        try {
            Object fileSystem = Class.forName("zombie.GameWindow").getField("fileSystem").get(null);
            int threads = Math.min(16, Math.max(4, Runtime.getRuntime().availableProcessors() - 4));
            ExecutorService pool = Executors.newFixedThreadPool(threads, task -> {
                Thread thread = new Thread(task, "AssetLoader");
                thread.setDaemon(true); // never holds the JVM open after the game quits
                return thread;
            });
            accessible(fileSystem.getClass().getDeclaredField("executor")).set(fileSystem, pool);
            System.out.println("ClickToStart: asset loading on " + threads + " threads");
        } catch (Exception e) {
            // Only slower: the game keeps its own pool.
            System.out.println("ClickToStart: couldn't widen asset loading: " + e);
        }
    }

    private static void clickWhenAsked() {
        try {
            while (!gameThreadStarted()) {
                Thread.sleep(POLL_MS);
            }
            widenAssetLoading();
            ClassLoader loader = ClickToStart.class.getClassLoader();
            Field states = Class.forName("zombie.GameWindow").getField("states");
            Field current = Class.forName("zombie.gameStates.GameStateMachine").getField("current");
            // Not initialized here: the game creates the instance before its fields are read.
            Class<?> loading = Class.forName("zombie.gameStates.GameLoadingState", false, loader);
            Field showedClickToSkip = accessible(loading.getDeclaredField("showedClickToSkip"));
            Field forceDone = accessible(loading.getDeclaredField("forceDone"));
            while (true) {
                Object state = current.get(states.get(null));
                if (loading.isInstance(state) && showedClickToSkip.getBoolean(null)) {
                    forceDone.setBoolean(state, true);
                    System.out.println("ClickToStart: pressed Click to start");
                    while (current.get(states.get(null)) == state) {
                        Thread.sleep(POLL_MS);
                    }
                }
                Thread.sleep(POLL_MS);
            }
        } catch (Exception e) {
            System.out.println("ClickToStart: failed, click by hand");
            e.printStackTrace(System.out);
        }
    }

    private static boolean gameThreadStarted() {
        for (Thread thread : Thread.getAllStackTraces().keySet()) {
            if ("MainThread".equals(thread.getName())) {
                return true;
            }
        }
        return false;
    }

    private static Field accessible(Field field) {
        field.setAccessible(true);
        return field;
    }
}
