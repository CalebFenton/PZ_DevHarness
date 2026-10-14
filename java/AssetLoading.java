import java.lang.reflect.Field;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * FileSystemImpl loads textures, meshes, animations and depth maps on a pool of at most 4 threads,
 * and both the client's loading screen and the dedicated server's start wait for all of them, with
 * all 4 threads busy throughout. ClickToStart and FastServer swap in a wider pool once the game has
 * created GameWindow.fileSystem.
 */
final class AssetLoading {
    private AssetLoading() {
    }

    /**
     * Gives GameWindow.fileSystem a pool of up to 16 threads. Tasks it has already handed to the old
     * pool finish there; the game keeps at most 16 tasks in flight, so more threads would idle.
     */
    static void widen() {
        try {
            Object fileSystem = Class.forName("zombie.GameWindow").getField("fileSystem").get(null);
            int threads = Math.min(16, Math.max(4, Runtime.getRuntime().availableProcessors() - 4));
            ExecutorService pool = Executors.newFixedThreadPool(threads, task -> {
                Thread thread = new Thread(task, "AssetLoader");
                thread.setDaemon(true); // never holds the JVM open after the game quits
                return thread;
            });
            Field executor = fileSystem.getClass().getDeclaredField("executor");
            executor.setAccessible(true);
            Object old = executor.get(fileSystem);
            executor.set(fileSystem, pool);
            // The old pool's threads would idle for the rest of the game. They end once idle instead
            // of the pool shutting down, since the game's thread may have read the old pool just
            // before the swap and still hand it a task, which a shut down pool would refuse.
            if (old instanceof ThreadPoolExecutor) {
                ((ThreadPoolExecutor) old).setKeepAliveTime(1, TimeUnit.SECONDS);
                ((ThreadPoolExecutor) old).allowCoreThreadTimeOut(true);
            }
            System.out.println("PZHarness: asset loading on " + threads + " threads");
        } catch (Exception e) {
            // Only slower: the game keeps its own pool.
            System.out.println("PZHarness: couldn't widen asset loading: " + e);
        }
    }
}
