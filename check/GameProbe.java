import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.io.Reader;
import java.lang.annotation.Annotation;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/*
 * Asks the installed game what check.py cannot read from its files.
 *
 *   GameProbe [--api <gameJar> <outFile>] [@<listFile>]
 *
 * --api writes what the game's Lua can reach, one fact per line (see writeApi). @listFile names
 * mod Lua files, one "path<TAB>display name" per line, and compiles each with the game's own
 * Kahlua compiler, so a syntax error shows here and not at the loading screen. Nothing runs.
 *
 * Run it from the game's Java folder on the game's own JVM, with projectzomboid.jar on the class
 * path: Kahlua reads stdlib.lua from the working directory, and the jar's classes are newer than
 * a JDK 8 javac can read. That is also why every game class is reached through reflection, so
 * that any javac from 8 on builds this.
 */
public class GameProbe {

    public static void main(String[] args) throws Exception {
        String jar = null;
        String apiOut = null;
        String list = null;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--api") && i + 2 < args.length) {
                jar = args[++i];
                apiOut = args[++i];
            } else if (args[i].startsWith("@")) {
                list = args[i].substring(1);
            } else {
                System.err.println("usage: GameProbe [--api <gameJar> <outFile>] [@<listFile>]");
                System.exit(2);
            }
        }
        Kahlua kahlua = new Kahlua();
        if (apiOut != null) writeApi(jar, apiOut, kahlua);
        if (list != null) System.exit(compileAll(list, kahlua) ? 0 : 1);
    }

    // ---------------------------------------------------------------------------------------
    // Compiling

    private static boolean compileAll(String listFile, Kahlua kahlua) throws Exception {
        List<String[]> files = new ArrayList<String[]>();
        BufferedReader lines = new BufferedReader(new InputStreamReader(new FileInputStream(listFile), "UTF-8"));
        try {
            for (String line; (line = lines.readLine()) != null; ) {
                if (line.trim().isEmpty()) continue;
                String[] parts = line.split("\t", 2);
                files.add(new String[] {parts[0], parts.length > 1 ? parts[1] : parts[0]});
            }
        } finally {
            lines.close();
        }

        List<String> failures = new ArrayList<String>();
        for (String[] file : files) {
            String error = kahlua.compile(file[0], file[1]);
            if (error != null) failures.add(error);
        }
        System.out.println("compiled " + (files.size() - failures.size()) + " of " + files.size()
            + " Lua files with the game's compiler");
        for (String failure : failures) System.out.println("FAIL   lua-syntax  " + failure);
        return failures.isEmpty();
    }

    /* The game's Lua platform and compiler. One environment serves every file, as in the game. */
    private static final class Kahlua {
        final Object environment;
        final Class<?> tableClass;
        final Method compile;

        Kahlua() throws Exception {
            Class<?> platform = Class.forName("se.krka.kahlua.j2se.J2SEPlatform");
            tableClass = Class.forName("se.krka.kahlua.vm.KahluaTable");
            environment = platform.getMethod("newEnvironment").invoke(platform.getConstructor().newInstance());
            compile = Class.forName("se.krka.kahlua.luaj.compiler.LuaCompiler")
                .getMethod("loadis", Reader.class, String.class, tableClass);
        }

        /* Null when the file compiles, else what the compiler said. LuaManager.RunLuaInternal
           reads mod files as UTF-8 and passes the file name, which its messages start with. */
        String compile(String path, String displayName) throws IOException {
            Reader reader = new BufferedReader(new InputStreamReader(new FileInputStream(path), "UTF-8"));
            try {
                compile.invoke(null, reader, displayName, environment);
                return null;
            } catch (InvocationTargetException e) {
                Throwable cause = e;
                while (cause.getCause() != null && cause.getCause() != cause) cause = cause.getCause();
                String message = cause.getMessage() == null ? cause.toString() : cause.getMessage();
                return message.startsWith(displayName) ? message : displayName + ": " + message;
            } catch (IllegalAccessException e) {
                throw new IllegalStateException(e);
            } finally {
                reader.close();
            }
        }

        /* Every key of a Kahlua table, through KahluaTable.iterator(). */
        List<Object[]> entries(Object table) throws Exception {
            List<Object[]> result = new ArrayList<Object[]>();
            Object iterator = tableClass.getMethod("iterator").invoke(table);
            Method advance = iterator.getClass().getMethod("advance");
            Method key = iterator.getClass().getMethod("getKey");
            Method value = iterator.getClass().getMethod("getValue");
            advance.setAccessible(true);
            key.setAccessible(true);
            value.setAccessible(true);
            while ((Boolean) advance.invoke(iterator)) {
                result.add(new Object[] {key.invoke(iterator), value.invoke(iterator)});
            }
            return result;
        }
    }

    // ---------------------------------------------------------------------------------------
    // What Lua can reach

    /*
     * Lines of the API file, sorted:
     *
     *   method <name>              an instance method of an exposed class, called obj:name()
     *   class <Name> <java.Name>   the global table of an exposed class
     *   static <Name> <member>     its static method or field, or new for a public constructor
     *   global <name>              any other global the engine sets before Lua runs
     *   member <table> <key>       a key of a standard library table, such as string or table
     *   event <name>               a string LuaEventManager holds, which covers every event name
     *   translation-file <name>    a Translate/<LANG>/<name>.json the Translator loads
     *   sandbox <name>             a string SandboxOptions holds, which covers every vanilla option
     *   item-field <name>          a string Item or Attribute holds, which covers every item script
     *                              key Item.DoParam knows (it compares each with equalsIgnoreCase)
     *
     * The exposed classes are those LuaManager$Exposer.exposeAll hands to setExposed, directly or
     * through UIWorldMap.setExposed and BuildingRoomsEditor.setExposed. Its shouldExpose answers
     * only for that set, so these are exactly the classes Lua gets a table and methods for. The
     * set is read from the class files' constant pools rather than by running exposeAll, which
     * would initialise a thousand game classes; the pools also name a few helper classes the
     * exposer uses for itself, which can only let a name through, never fail one.
     */
    private static void writeApi(String jarPath, String outPath, Kahlua kahlua) throws Exception {
        TreeSet<String> facts = new TreeSet<String>();
        List<String> unloadable = new ArrayList<String>();
        ZipFile jar = new ZipFile(jarPath);
        try {
            TreeSet<String> exposed = new TreeSet<String>();
            for (String exposer : new String[] {"zombie/Lua/LuaManager$Exposer", "zombie/worldMap/UIWorldMap",
                                                "zombie/buildingRooms/BuildingRoomsEditor"}) {
                exposed.addAll(ConstantPool.read(jar, exposer).classes);
            }
            ClassLoader loader = GameProbe.class.getClassLoader();
            for (String internalName : exposed) {
                if (internalName.startsWith("[")) continue;
                try {
                    describeClass(Class.forName(internalName.replace('/', '.'), false, loader), facts);
                } catch (Throwable t) {
                    // Reading its methods initialised something that needs the running game. Its
                    // table still exists, so at least its name counts.
                    String java = internalName.replace('/', '.');
                    facts.add("class " + java.substring(java.lastIndexOf('.') + 1).replaceAll(".*\\$", "") + " " + java);
                    unloadable.add(internalName + " (" + t + ")");
                }
            }

            JarIndex index = new JarIndex(jar);
            strings(jar, index.classes("zombie/Lua/LuaEventManager"), "event", facts);
            // Translator.BY_NAME is filled in an anonymous subclass, whose only strings are the names.
            strings(jar, java.util.Collections.singletonList("zombie/core/Translator$1"), "translation-file", facts);
            strings(jar, index.classes("zombie/SandboxOptions"), "sandbox", facts);
            strings(jar, index.classes("zombie/scripting/objects/Item"), "item-field", facts);
            strings(jar, index.classes("zombie/entity/components/attributes/Attribute"), "item-field", facts);
        } finally {
            jar.close();
        }

        globalFunctions(facts);
        for (Object[] entry : kahlua.entries(kahlua.environment)) {
            if (!(entry[0] instanceof String)) continue;
            facts.add("global " + entry[0]);
            if (kahlua.tableClass.isInstance(entry[1])) {
                for (Object[] member : kahlua.entries(entry[1])) {
                    if (member[0] instanceof String) facts.add("member " + entry[0] + " " + member[0]);
                }
            }
        }

        PrintWriter out = new PrintWriter(new OutputStreamWriter(new java.io.FileOutputStream(outPath), "UTF-8"));
        try {
            for (String fact : facts) out.println(fact);
        } finally {
            out.close();
        }
        System.out.println("game API: " + facts.size() + " facts");
        // Their methods go unchecked: a call of one would be reported as unknown.
        for (String name : unloadable) System.out.println("note   could not read the methods of exposed class " + name);
    }

    /* The identifier-like string literals of these classes, as facts of one kind. */
    private static void strings(ZipFile jar, List<String> classNames, String kind, TreeSet<String> facts)
            throws IOException {
        for (String className : classNames) {
            for (String s : ConstantPool.read(jar, className).strings) {
                if (s.matches("[A-Za-z0-9_.]+")) facts.add(kind + " " + s);
            }
        }
    }

    /* What LuaJavaClassExposer.exposeLikeJava gives Lua for one class. */
    private static void describeClass(Class<?> c, TreeSet<String> facts) {
        if (hidden(c)) return;
        // Lua reaches a class also through its package path, as in zombie.iso.IsoObject.
        facts.add("global " + c.getName().split("\\.")[0]);
        String simple = c.getSimpleName();
        boolean statics = !c.isSynthetic() && !c.isAnonymousClass() && !simple.isEmpty() && !simple.startsWith("$");
        if (statics) facts.add("class " + simple + " " + c.getName());
        for (Method m : c.getMethods()) {
            if (hidden(m)) continue;
            if (!Modifier.isStatic(m.getModifiers())) facts.add("method " + m.getName());
            else if (statics) facts.add("static " + simple + " " + m.getName());
        }
        if (!statics) return;
        for (Field f : c.getFields()) {
            if (Modifier.isStatic(f.getModifiers()) && !hidden(f)) {
                facts.add("static " + simple + " " + f.getName());
            }
        }
        if (!c.isInterface() && !Modifier.isAbstract(c.getModifiers())) {
            for (Constructor<?> k : c.getConstructors()) {
                if (!hidden(k)) facts.add("static " + simple + " new");
            }
        }
        facts.add("static " + simple + " class");
        // The class's table sits at its name's path, which runs through the table of the class
        // that encloses it, so ItemKey.Normal is ItemKey$Normal.
        String[] path = c.getName().substring(c.getName().lastIndexOf('.') + 1).split("\\$");
        if (path.length > 1) facts.add("static " + path[path.length - 2] + " " + path[path.length - 1]);
    }

    /* Whether it carries @HiddenFromLua. Reading annotations builds their values, and an enum value
       initialises its enum, which for a few network classes needs the running game; nothing hides
       those, so a failure reads as not hidden. */
    private static boolean hidden(java.lang.reflect.AnnotatedElement element) {
        try {
            for (Annotation a : element.getAnnotations()) {
                if (a.annotationType().getName().equals("zombie.HiddenFromLua")) return true;
            }
        } catch (Throwable t) {
            return false;
        }
        return false;
    }

    /* The global functions: LuaManager$GlobalObject's methods marked @LuaMethod(global = true),
       under the annotation's name when it gives one (LuaJavaClassExposer.exposeGlobalFunctions). */
    @SuppressWarnings("unchecked")
    private static void globalFunctions(TreeSet<String> facts) throws Exception {
        Class<? extends Annotation> luaMethod =
            (Class<? extends Annotation>) Class.forName("se.krka.kahlua.integration.annotations.LuaMethod");
        Method name = luaMethod.getMethod("name");
        Method global = luaMethod.getMethod("global");
        Class<?> globals = Class.forName("zombie.Lua.LuaManager$GlobalObject", false, GameProbe.class.getClassLoader());
        for (Method m : globals.getMethods()) {
            Annotation a = m.getAnnotation(luaMethod);
            if (a == null || !(Boolean) global.invoke(a)) continue;
            String given = (String) name.invoke(a);
            facts.add("global " + (given.isEmpty() ? m.getName() : given));
        }
    }

    /* The jar's entries, for picking out a class and its nested classes. */
    private static final class JarIndex {
        final List<String> names = new ArrayList<String>();

        JarIndex(ZipFile jar) {
            for (java.util.Enumeration<? extends ZipEntry> e = jar.entries(); e.hasMoreElements(); ) {
                names.add(e.nextElement().getName());
            }
        }

        List<String> classes(String className) {
            List<String> result = new ArrayList<String>();
            for (String n : names) {
                if (n.equals(className + ".class") || (n.startsWith(className + "$") && n.endsWith(".class"))) {
                    result.add(n.substring(0, n.length() - ".class".length()));
                }
            }
            return result;
        }
    }

    /* The classes a class file refers to and the string literals it holds, from its constant
       pool (JVM specification 4.4). */
    private static final class ConstantPool {
        final List<String> classes = new ArrayList<String>();
        final List<String> strings = new ArrayList<String>();

        static ConstantPool read(ZipFile jar, String className) throws IOException {
            ZipEntry entry = jar.getEntry(className + ".class");
            if (entry == null) throw new IOException(className + " is not in " + jar.getName());
            InputStream in = jar.getInputStream(entry);
            try {
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                for (int n; (n = in.read(buffer)) > 0; ) bytes.write(buffer, 0, n);
                return new ConstantPool(bytes.toByteArray());
            } finally {
                in.close();
            }
        }

        ConstantPool(byte[] classFile) throws IOException {
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(classFile));
            if (in.readInt() != 0xCAFEBABE) throw new IOException("not a class file");
            in.readUnsignedShort();
            in.readUnsignedShort();
            int count = in.readUnsignedShort();
            String[] utf8 = new String[count];
            List<Integer> classIndexes = new ArrayList<Integer>();
            List<Integer> stringIndexes = new ArrayList<Integer>();
            for (int i = 1; i < count; i++) {
                int tag = in.readUnsignedByte();
                switch (tag) {
                    case 1: utf8[i] = in.readUTF(); break;
                    case 7: classIndexes.add(in.readUnsignedShort()); break;
                    case 8: stringIndexes.add(in.readUnsignedShort()); break;
                    case 16: case 19: case 20: in.skipBytes(2); break;
                    case 15: in.skipBytes(3); break;
                    case 3: case 4: case 9: case 10: case 11: case 12: case 17: case 18: in.skipBytes(4); break;
                    // A long or a double fills two pool slots.
                    case 5: case 6: in.skipBytes(8); i++; break;
                    default: throw new IOException("unknown constant pool tag " + tag);
                }
            }
            for (int index : classIndexes) classes.add(utf8[index]);
            for (int index : stringIndexes) strings.add(utf8[index]);
        }
    }
}
