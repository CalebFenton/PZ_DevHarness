import java.lang.reflect.Field;

/**
 * Sends every packet type at RakNet's IMMEDIATE priority instead of the HIGH, MEDIUM or LOW the
 * game gives it (PacketTypes.PacketType.packetPriority). RakNet sends the others only on its
 * network thread's next pass, about every 10 ms, so each leg of a harness server call, and of
 * every sync the tests wait for, waited on that pass. All types get the same priority, so their
 * relative order stays as the game sends them.
 *
 * Reading PacketType here before the game has would initialize it out of the game's startup
 * order, so this waits for the game's network thread, which exists only once the game has
 * started its networking: a dedicated server's, or a client joining one. A single player game
 * never starts it, so there the wait goes on, a cheap look at the thread list twice a second.
 */
final class NetLatency {
    private static final long POLL_MS = 500;
    private static final int IMMEDIATE_PRIORITY = 0;

    private NetLatency() {
    }

    static void immediateOnceNetworking() {
        Thread waiter = new Thread(NetLatency::waitAndSet, "NetLatency");
        waiter.setDaemon(true);
        waiter.start();
    }

    private static void waitAndSet() {
        try {
            while (!networking()) {
                Thread.sleep(POLL_MS);
            }
            Class<?> type = Class.forName("zombie.network.PacketTypes$PacketType");
            Field priority = type.getField("packetPriority");
            for (Object packet : type.getEnumConstants()) {
                priority.setInt(packet, IMMEDIATE_PRIORITY);
            }
            System.out.println("NetLatency: every packet type sends at IMMEDIATE priority");
        } catch (Exception e) {
            // Only slower: the packets keep the game's priorities.
            System.out.println("NetLatency: failed, packets keep the game's priorities");
            e.printStackTrace(System.out);
        }
    }

    private static boolean networking() {
        ThreadGroup root = Thread.currentThread().getThreadGroup();
        while (root.getParent() != null) {
            root = root.getParent();
        }
        Thread[] threads = new Thread[root.activeCount() * 2];
        int count = root.enumerate(threads, true);
        for (int i = 0; i < count; i++) {
            if ("UdpEngine".equals(threads[i].getName())) {
                return true;
            }
        }
        return false;
    }
}
