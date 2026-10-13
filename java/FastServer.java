/**
 * Starts the dedicated server with more asset loader threads, as ClickToStart does for the client:
 * before it starts, the server waits for the game's models, animations and clothing to load on the
 * same pool of at most 4 threads, all of them busy throughout.
 *
 * Reading a static field of a class that isn't initialized yet would initialize it here, out of
 * the server's startup order, so this waits until the server's main thread is in the loop of
 * GameServer.doMinimumInit that waits for GameWindow.fileSystem's loads, which only runs once
 * GameWindow is initialized.
 */
public class FastServer {
    private static final long POLL_MS = 20;

    public static void main(String[] args) throws Exception {
        Thread main = Thread.currentThread();
        Thread widener = new Thread(() -> widenOnceLoading(main), "FastServer");
        widener.setDaemon(true);
        widener.start();
        Class.forName("zombie.network.GameServer").getMethod("main", String[].class).invoke(null, (Object) args);
    }

    private static void widenOnceLoading(Thread main) {
        try {
            while (!waitingForAssets(main)) {
                if (!main.isAlive()) {
                    return;
                }
                Thread.sleep(POLL_MS);
            }
            AssetLoading.widen();
        } catch (InterruptedException e) {
            // Only slower: the server keeps its own pool.
        }
    }

    private static boolean waitingForAssets(Thread main) {
        boolean inFileSystem = false;
        for (StackTraceElement frame : main.getStackTrace()) {
            if (frame.getClassName().equals("zombie.fileSystem.FileSystemImpl")) {
                inFileSystem = true;
            } else if (inFileSystem && frame.getClassName().equals("zombie.network.GameServer")
                    && frame.getMethodName().equals("doMinimumInit")) {
                return true;
            }
        }
        return false;
    }
}
