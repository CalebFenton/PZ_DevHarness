import java.lang.reflect.Field;

/**
 * Starts the game client and presses "Click to start" whenever the loading screen shows it, so
 * the unattended runs of bin/run-client.sh (--test and the mod's own modes) need no one at the
 * computer. It also gives the game's asset loader more threads (AssetLoading), loads the tile
 * depth maps early (DepthMaps), which shortens loading, and in multiplayer sends packets at once
 * (NetLatency).
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
        NetLatency.immediateOnceNetworking();
        Class.forName("zombie.gameStates.MainScreenState").getMethod("main", String[].class).invoke(null, (Object) args);
    }

    private static void clickWhenAsked() {
        try {
            while (!gameThreadStarted()) {
                Thread.sleep(POLL_MS);
            }
            AssetLoading.widen();
            DepthMaps.preloadOnceQueued();
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
