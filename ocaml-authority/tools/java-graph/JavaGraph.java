/*
 * JavaGraph: parse-only extractor for the java-source-graph/v1 format consumed by
 * lib/proof (see docs/proof-search.md).
 *
 *   java tools/java-graph/JavaGraph.java --root REPO --commit SHA [--out FILE] (--slice LIST | PATH...)
 *
 * PATHs (or the lines of LIST) are relative to REPO. Only the JDK compiler tree API
 * is used, and only its parser: no attribution, no classpath. Type references are
 * resolved by name, in this order:
 *
 *   1. type variables of the enclosing method and types
 *   2. member types of the lexically enclosing types (and those types themselves)
 *   3. single-type imports
 *   4. top-level slice types of the same package
 *   5. a fixed list of java.lang names
 *   6. otherwise: assumed to live in the same package (no on-demand import in the file),
 *      or unknown (the file has on-demand imports)
 *
 * A reference is "slice" if it names a type declared in one of the input files, "jdk"
 * if its qualified name is one of JDK_KNOWN, and "external" otherwise. Inherited member
 * types, static imports and anything that needs attribution are not seen.
 *
 * Output order is deterministic: files sorted by path, types sorted by id, members and
 * enum constants in source order.
 */

import com.sun.source.tree.*;
import com.sun.source.util.JavacTask;
import com.sun.source.util.SourcePositions;
import com.sun.source.util.TreeScanner;
import com.sun.source.util.Trees;

import javax.lang.model.element.Modifier;
import javax.tools.*;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;

public class JavaGraph {

    static final String SCHEMA = "java-source-graph/v1";

    /** The JDK types proof-search.md treats as known. Every other non-slice type is external. */
    static final Set<String> JDK_KNOWN = Set.of(
            "java.lang.String", "java.lang.Object", "java.lang.Class",
            "java.lang.Boolean", "java.lang.Byte", "java.lang.Short", "java.lang.Character",
            "java.lang.Integer", "java.lang.Long", "java.lang.Float", "java.lang.Double",
            "java.util.List", "java.util.Set", "java.util.Map", "java.util.Collection");

    /** java.lang names recognised without an import (step 5). */
    static final Set<String> JAVA_LANG = Set.of(
            "String", "Object", "Class", "Boolean", "Byte", "Short", "Character", "Integer", "Long",
            "Float", "Double", "Void", "Number", "CharSequence", "Iterable", "Comparable", "Enum",
            "Record", "Throwable", "Exception", "RuntimeException", "Error", "AutoCloseable",
            "Cloneable", "Runnable", "Override", "Deprecated", "SuppressWarnings",
            "FunctionalInterface", "SafeVarargs");

    // ---------------------------------------------------------------- input

    record Unit(String path, String source, CompilationUnitTree tree, String pkg,
                Map<String, String> singleImports, boolean hasOnDemandImports) {}

    /** A declared type of the slice, before extraction. */
    record Decl(String id, String qualified, Unit unit, ClassTree tree, List<String> enclosingIds) {}

    final Map<String, Decl> byId = new TreeMap<>();
    final Map<String, Decl> byQualified = new HashMap<>();
    SourcePositions positions;

    public static void main(String[] args) throws Exception {
        Path root = null;
        String commit = null;
        Path out = null;
        List<String> paths = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--root" -> root = Path.of(args[++i]);
                case "--commit" -> commit = args[++i];
                case "--out" -> out = Path.of(args[++i]);
                case "--slice" -> {
                    for (String line : Files.readAllLines(Path.of(args[++i]), StandardCharsets.UTF_8)) {
                        String p = line.strip();
                        if (!p.isEmpty() && !p.startsWith("#")) paths.add(p);
                    }
                }
                default -> paths.add(args[i]);
            }
        }
        if (root == null || commit == null || paths.isEmpty()) {
            System.err.println("usage: JavaGraph --root REPO --commit SHA [--out FILE] (--slice LIST | PATH...)");
            System.exit(2);
        }
        String json = new JavaGraph().run(root, commit, paths);
        if (out == null) System.out.print(json);
        else Files.writeString(out, json, StandardCharsets.UTF_8);
    }

    String run(Path root, String commit, List<String> relPaths) throws IOException {
        List<String> sorted = new ArrayList<>(new TreeSet<>(relPaths));
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        StandardJavaFileManager fm = compiler.getStandardFileManager(null, Locale.ROOT, StandardCharsets.UTF_8);
        DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
        List<JavaFileObject> objects = new ArrayList<>();
        for (String p : sorted) objects.add(fm.getJavaFileObjects(root.resolve(p)).iterator().next());
        JavacTask task = (JavacTask) compiler.getTask(null, fm, diagnostics, List.of("-proc:none"), null, objects);
        Map<java.net.URI, CompilationUnitTree> trees = new HashMap<>();
        for (CompilationUnitTree cu : task.parse()) trees.put(cu.getSourceFile().toUri(), cu);
        for (Diagnostic<?> d : diagnostics.getDiagnostics()) {
            if (d.getKind() == Diagnostic.Kind.ERROR) throw new IllegalStateException("parse error: " + d);
        }
        positions = Trees.instance(task).getSourcePositions();

        List<Object> files = new ArrayList<>();
        for (int i = 0; i < sorted.size(); i++) {
            byte[] bytes = Files.readAllBytes(root.resolve(sorted.get(i)));
            CompilationUnitTree cu = trees.get(objects.get(i).toUri());
            Unit u = unitOf(sorted.get(i), new String(bytes, StandardCharsets.UTF_8), cu);
            files.add(obj("path", u.path, "git_blob", gitBlobSha1(bytes)));
            for (Tree t : u.tree.getTypeDecls()) {
                if (t instanceof ClassTree ct) declare(u, ct, List.of());
            }
        }

        List<Object> types = new ArrayList<>();
        for (Decl d : byId.values()) types.add(typeJson(d));

        Map<String, Object> source = obj(
                "commit", commit,
                "extractor", "tools/java-graph/JavaGraph.java",
                "resolution", "parse-only",
                "files", files);
        return Json.write(obj("schema", SCHEMA, "source", source, "types", types)) + "\n";
    }

    Unit unitOf(String path, String source, CompilationUnitTree cu) {
        String pkg = cu.getPackageName() == null ? "" : cu.getPackageName().toString();
        Map<String, String> single = new HashMap<>();
        boolean onDemand = false;
        for (ImportTree it : cu.getImports()) {
            if (it.isStatic()) continue;
            String q = it.getQualifiedIdentifier().toString();
            if (q.endsWith(".*")) onDemand = true;
            else single.put(q.substring(q.lastIndexOf('.') + 1), q);
        }
        return new Unit(path, source, cu, pkg, single, onDemand);
    }

    void declare(Unit u, ClassTree ct, List<String> enclosing) {
        String simple = ct.getSimpleName().toString();
        String id = enclosing.isEmpty() ? simple : enclosing.get(enclosing.size() - 1) + "." + simple;
        String qualified = u.pkg.isEmpty() ? id : u.pkg + "." + id;
        Decl d = new Decl(id, qualified, u, ct, enclosing);
        if (byId.put(id, d) != null) throw new IllegalStateException("duplicate type id in slice: " + id);
        byQualified.put(qualified, d);
        List<String> inner = new ArrayList<>(enclosing);
        inner.add(id);
        for (Tree m : ct.getMembers()) {
            if (m instanceof ClassTree nested) declare(u, nested, List.copyOf(inner));
        }
    }

    // ---------------------------------------------------------------- types and members

    Map<String, Object> typeJson(Decl d) {
        ClassTree ct = d.tree;
        Unit u = d.unit;
        Scope scope = new Scope(u, d, typeParamNames(ct.getTypeParameters()), List.of());
        String kind = switch (ct.getKind()) {
            case INTERFACE -> "interface";
            case ENUM -> "enum";
            case RECORD -> "record";
            case ANNOTATION_TYPE -> "annotation";
            default -> "class";
        };
        List<Object> ext = new ArrayList<>();
        List<Object> impl = new ArrayList<>();
        if (ct.getExtendsClause() != null) ext.add(typeRef(ct.getExtendsClause(), scope));
        // For an interface the parser stores the extended interfaces in the implements clause.
        for (Tree t : ct.getImplementsClause()) (kind.equals("interface") ? ext : impl).add(typeRef(t, scope));

        List<Object> constants = new ArrayList<>();
        List<Object> members = new ArrayList<>();
        for (Tree m : ct.getMembers()) {
            if (m instanceof VariableTree vt && isEnumConstant(ct, vt)) {
                constants.add(obj(
                        "name", vt.getName().toString(),
                        "line", nameLine(u, vt, null, vt.getName().toString()),
                        "annotations", annotations(vt.getModifiers(), scope)));
            } else if (m instanceof VariableTree vt) {
                members.add(fieldJson(d, vt, scope));
            } else if (m instanceof MethodTree mt) {
                members.add(methodJson(d, mt, scope));
            }
            // Nested types are separate entries; initializer blocks carry no member.
        }
        Decl outer = d.enclosingIds.isEmpty() ? null : byId.get(d.enclosingIds.get(d.enclosingIds.size() - 1));
        return obj(
                "id", d.id,
                "qualified_name", d.qualified,
                "kind", kind,
                "file", u.path,
                "line", nameLine(u, ct, ct.getModifiers(), ct.getSimpleName().toString()),
                "enclosing", outer == null ? null : outer.id,
                "modifiers", modifiers(ct.getModifiers(), implicitTypeModifiers(ct, outer)),
                "annotations", annotations(ct.getModifiers(), scope),
                "type_params", typeParams(ct.getTypeParameters(), scope),
                "extends", ext,
                "implements", impl,
                "constants", constants,
                "members", members);
    }

    static boolean isEnumConstant(ClassTree owner, VariableTree vt) {
        return owner.getKind() == Tree.Kind.ENUM
                && vt.getType() instanceof IdentifierTree id
                && id.getName().contentEquals(owner.getSimpleName())
                && vt.getInitializer() instanceof NewClassTree;
    }

    Map<String, Object> fieldJson(Decl d, VariableTree vt, Scope scope) {
        boolean component = d.tree.getKind() == Tree.Kind.RECORD
                && !vt.getModifiers().getFlags().contains(Modifier.STATIC);
        List<String> mods = component
                // The component's accessor is public; its backing field is private final.
                ? List.of("final")
                : modifiers(vt.getModifiers(), implicitFieldModifiers(d.tree));
        return obj(
                "kind", component ? "component" : "field",
                "name", vt.getName().toString(),
                "line", nameLine(d.unit, vt, vt.getType(), vt.getName().toString()),
                "modifiers", mods,
                "annotations", annotations(vt.getModifiers(), scope),
                "type_params", List.of(),
                "type", typeRef(vt.getType(), scope),
                "params", List.of(),
                "throws", List.of(),
                "has_body", false,
                "returns_null_literal", false);
    }

    Map<String, Object> methodJson(Decl d, MethodTree mt, Scope typeScope) {
        boolean ctor = mt.getName().contentEquals("<init>");
        String name = ctor ? d.tree.getSimpleName().toString() : mt.getName().toString();
        Scope scope = typeScope.withMethodVars(typeParamNames(mt.getTypeParameters()));
        List<Object> params = new ArrayList<>();
        for (VariableTree p : mt.getParameters()) {
            params.add(obj(
                    "name", p.getName().toString(),
                    "type", typeRef(p.getType(), scope),
                    "varargs", isVarargs(d.unit, p),
                    "annotations", annotations(p.getModifiers(), scope)));
        }
        List<Object> throwsList = new ArrayList<>();
        for (ExpressionTree t : mt.getThrows()) throwsList.add(typeRef(t, scope));
        Tree anchor = ctor ? null : mt.getReturnType();
        return obj(
                "kind", ctor ? "constructor" : "method",
                "name", name,
                "line", nameLine(d.unit, mt, anchor, name),
                "modifiers", modifiers(mt.getModifiers(), implicitMethodModifiers(d.tree, mt, ctor)),
                "annotations", annotations(mt.getModifiers(), scope),
                "type_params", typeParams(mt.getTypeParameters(), scope),
                "type", ctor ? null : typeRef(mt.getReturnType(), scope),
                "params", params,
                "throws", throwsList,
                "has_body", mt.getBody() != null,
                "returns_null_literal", mt.getBody() != null && returnsNullLiteral(mt.getBody()));
    }

    // ---------------------------------------------------------------- modifiers

    static List<String> modifiers(ModifiersTree mods, Set<Modifier> implicit) {
        EnumSet<Modifier> all = EnumSet.noneOf(Modifier.class);
        all.addAll(mods.getFlags());
        all.addAll(implicit);
        List<String> out = new ArrayList<>();
        for (Modifier m : all) out.add(m.toString());
        return out;
    }

    /** JLS 9.3, 9.4, 9.5 and 8.9: modifiers implied by the declaration context. */
    static Set<Modifier> implicitTypeModifiers(ClassTree ct, Decl outer) {
        EnumSet<Modifier> s = EnumSet.noneOf(Modifier.class);
        if (ct.getKind() == Tree.Kind.INTERFACE || ct.getKind() == Tree.Kind.ANNOTATION_TYPE) s.add(Modifier.ABSTRACT);
        if (ct.getKind() == Tree.Kind.RECORD) s.add(Modifier.FINAL);
        if (outer != null) {
            if (ct.getKind() != Tree.Kind.CLASS) s.add(Modifier.STATIC);
            if (outer.tree.getKind() == Tree.Kind.INTERFACE) {
                s.add(Modifier.PUBLIC);
                s.add(Modifier.STATIC);
            }
        }
        return s;
    }

    static Set<Modifier> implicitFieldModifiers(ClassTree owner) {
        if (owner.getKind() == Tree.Kind.INTERFACE) return EnumSet.of(Modifier.PUBLIC, Modifier.STATIC, Modifier.FINAL);
        return EnumSet.noneOf(Modifier.class);
    }

    static Set<Modifier> implicitMethodModifiers(ClassTree owner, MethodTree mt, boolean ctor) {
        Set<Modifier> written = mt.getModifiers().getFlags();
        EnumSet<Modifier> s = EnumSet.noneOf(Modifier.class);
        if (ctor && owner.getKind() == Tree.Kind.ENUM) s.add(Modifier.PRIVATE);
        if (owner.getKind() == Tree.Kind.INTERFACE && !written.contains(Modifier.PRIVATE)) {
            s.add(Modifier.PUBLIC);
            if (mt.getBody() == null && !written.contains(Modifier.STATIC)) s.add(Modifier.ABSTRACT);
        }
        return s;
    }

    // ---------------------------------------------------------------- body facts

    /** True if some return statement of this body (not of a nested lambda or class) can yield the null literal. */
    static boolean returnsNullLiteral(BlockTree body) {
        boolean[] found = {false};
        new TreeScanner<Void, Void>() {
            @Override
            public Void visitReturn(ReturnTree r, Void v) {
                if (mayBeNullLiteral(r.getExpression())) found[0] = true;
                return super.visitReturn(r, v);
            }

            @Override
            public Void visitLambdaExpression(LambdaExpressionTree l, Void v) {
                return null;
            }

            @Override
            public Void visitClass(ClassTree c, Void v) {
                return null;
            }
        }.scan(body, null);
        return found[0];
    }

    static boolean mayBeNullLiteral(ExpressionTree e) {
        if (e == null) return false;
        return switch (e.getKind()) {
            case NULL_LITERAL -> true;
            case PARENTHESIZED -> mayBeNullLiteral(((ParenthesizedTree) e).getExpression());
            case CONDITIONAL_EXPRESSION -> {
                ConditionalExpressionTree c = (ConditionalExpressionTree) e;
                yield mayBeNullLiteral(c.getTrueExpression()) || mayBeNullLiteral(c.getFalseExpression());
            }
            default -> false;
        };
    }

    boolean isVarargs(Unit u, VariableTree p) {
        // The parser records varargs only in an internal flag; the source text is unambiguous.
        return u.source.substring((int) startPos(u, p.getType()), (int) endPos(u, p)).contains("...");
    }

    // ---------------------------------------------------------------- type references

    /** Names in scope for resolution. */
    record Scope(Unit unit, Decl decl, List<String> typeVars, List<String> methodVars) {
        Scope withMethodVars(List<String> vars) {
            return new Scope(unit, decl, typeVars, vars);
        }
    }

    Object typeRef(Tree t, Scope sc) {
        switch (t.getKind()) {
            case PRIMITIVE_TYPE: {
                String k = ((PrimitiveTypeTree) t).getPrimitiveTypeKind().toString().toLowerCase(Locale.ROOT);
                return k.equals("void") ? obj("kind", "void") : obj("kind", "primitive", "name", k);
            }
            case ARRAY_TYPE:
                return obj("kind", "array", "element", typeRef(((ArrayTypeTree) t).getType(), sc));
            case PARAMETERIZED_TYPE: {
                ParameterizedTypeTree pt = (ParameterizedTypeTree) t;
                List<Object> args = new ArrayList<>();
                for (Tree a : pt.getTypeArguments()) args.add(typeRef(a, sc));
                return classRef(pt.getType(), args, sc);
            }
            case IDENTIFIER:
            case MEMBER_SELECT: {
                String written = t.toString();
                if (!written.contains(".") && (sc.methodVars.contains(written) || sc.typeVars.contains(written)))
                    return obj("kind", "type_var", "name", written);
                return classRef(t, List.of(), sc);
            }
            case UNBOUNDED_WILDCARD:
                return obj("kind", "wildcard", "bound", null);
            case EXTENDS_WILDCARD:
            case SUPER_WILDCARD: {
                WildcardTree w = (WildcardTree) t;
                String rel = t.getKind() == Tree.Kind.EXTENDS_WILDCARD ? "extends" : "super";
                return obj("kind", "wildcard", "bound", obj("relation", rel, "type", typeRef(w.getBound(), sc)));
            }
            case ANNOTATED_TYPE:
                return typeRef(((AnnotatedTypeTree) t).getUnderlyingType(), sc);
            default:
                throw new IllegalStateException("unsupported type tree " + t.getKind() + ": " + t);
        }
    }

    Map<String, Object> classRef(Tree nameTree, List<Object> args, Scope sc) {
        String written = nameTree.toString();
        String[] parts = written.split("\\.");
        Resolved r = resolveSimple(parts[0], sc);
        if (r == null) {
            // The first segment is not a type, so the whole name is fully qualified.
            r = named(written, "qualified");
        } else {
            for (int i = 1; i < parts.length; i++) r = select(r, parts[i]);
        }
        return obj(
                "kind", "class",
                "written", written,
                "resolution", r.resolution,
                "name", r.name,
                "basis", r.basis,
                "args", args);
    }

    /** resolution is "slice" (name is a slice type id), "jdk" or "external" (name is qualified). */
    record Resolved(String resolution, String name, String basis) {}

    Resolved named(String qualified, String basis) {
        Decl d = byQualified.get(qualified);
        if (d != null) return new Resolved("slice", d.id, basis);
        return new Resolved(JDK_KNOWN.contains(qualified) ? "jdk" : "external", qualified, basis);
    }

    Resolved select(Resolved r, String member) {
        if (r.resolution.equals("slice")) {
            String nested = r.name + "." + member;
            if (byId.containsKey(nested)) return new Resolved("slice", nested, r.basis);
            // An inherited member type: not visible to a parse-only extractor.
            return new Resolved("external", byId.get(r.name).qualified + "." + member, r.basis);
        }
        return named(r.name + "." + member, r.basis);
    }

    /** Steps 1-6 of the header comment for the first segment of a name; null if it is a package. */
    Resolved resolveSimple(String n, Scope sc) {
        List<String> chain = new ArrayList<>(sc.decl.enclosingIds);
        chain.add(sc.decl.id);
        for (int i = chain.size() - 1; i >= 0; i--) {
            String id = chain.get(i);
            if (simpleName(id).equals(n)) return new Resolved("slice", id, "enclosing");
            if (byId.containsKey(id + "." + n)) return new Resolved("slice", id + "." + n, "enclosing");
        }
        String imported = sc.unit.singleImports.get(n);
        if (imported != null) return named(imported, "import");
        String samePkg = sc.unit.pkg.isEmpty() ? n : sc.unit.pkg + "." + n;
        if (byQualified.containsKey(samePkg)) return named(samePkg, "same_package");
        if (JAVA_LANG.contains(n)) return named("java.lang." + n, "java.lang");
        if (Character.isLowerCase(n.charAt(0))) return null;
        if (sc.unit.hasOnDemandImports) return new Resolved("external", n, "unknown");
        return named(samePkg, "assumed_same_package");
    }

    static String simpleName(String id) {
        return id.substring(id.lastIndexOf('.') + 1);
    }

    List<String> typeParamNames(List<? extends TypeParameterTree> tps) {
        List<String> names = new ArrayList<>();
        for (TypeParameterTree tp : tps) names.add(tp.getName().toString());
        return names;
    }

    List<Object> typeParams(List<? extends TypeParameterTree> tps, Scope sc) {
        List<Object> out = new ArrayList<>();
        for (TypeParameterTree tp : tps) {
            List<Object> bounds = new ArrayList<>();
            for (Tree b : tp.getBounds()) bounds.add(typeRef(b, sc));
            out.add(obj("name", tp.getName().toString(), "bounds", bounds));
        }
        return out;
    }

    List<Object> annotations(ModifiersTree mods, Scope sc) {
        List<Object> out = new ArrayList<>();
        for (AnnotationTree a : mods.getAnnotations()) {
            String written = a.getAnnotationType().toString();
            String head = written.contains(".") ? null : sc.unit.singleImports.get(written);
            List<Object> argTexts = new ArrayList<>();
            for (ExpressionTree e : a.getArguments()) argTexts.add(sourceText(sc.unit, e));
            out.add(obj(
                    "name", written,
                    "qualified", head,
                    "arguments", argTexts,
                    "line", line(sc.unit, startPos(sc.unit, a))));
        }
        return out;
    }

    // ---------------------------------------------------------------- positions

    long startPos(Unit u, Tree t) {
        return positions.getStartPosition(u.tree, t);
    }

    long endPos(Unit u, Tree t) {
        return positions.getEndPosition(u.tree, t);
    }

    String sourceText(Unit u, Tree t) {
        return u.source.substring((int) startPos(u, t), (int) endPos(u, t));
    }

    static int line(Unit u, long pos) {
        return (int) u.tree.getLineMap().getLineNumber(pos);
    }

    /** Line of the first whole-word occurrence of [name] after [anchor] (or after the start of [t]). */
    int nameLine(Unit u, Tree t, Tree anchor, String name) {
        long from = startPos(u, t);
        if (anchor != null) {
            long end = endPos(u, anchor);
            if (end > from) from = end;
        }
        String s = u.source;
        for (int i = s.indexOf(name, (int) from); i >= 0; i = s.indexOf(name, i + 1)) {
            boolean before = i == 0 || !Character.isJavaIdentifierPart(s.charAt(i - 1));
            int j = i + name.length();
            boolean after = j >= s.length() || !Character.isJavaIdentifierPart(s.charAt(j));
            if (before && after) return line(u, i);
        }
        return line(u, startPos(u, t));
    }

    static String gitBlobSha1(byte[] content) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            md.update(("blob " + content.length + "\0").getBytes(StandardCharsets.US_ASCII));
            md.update(content);
            return HexFormat.of().formatHex(md.digest());
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    // ---------------------------------------------------------------- JSON

    static Map<String, Object> obj(Object... kvs) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kvs.length; i += 2) m.put((String) kvs[i], kvs[i + 1]);
        return m;
    }

    /** Pretty printer that keeps a container on one line when it fits in 100 columns. */
    static final class Json {
        /** Type references are always printed on one line. */
        static final Set<Object> TYPE_REF_KINDS = Set.of("class", "primitive", "array", "type_var", "wildcard", "void");

        static String write(Object v) {
            StringBuilder b = new StringBuilder();
            pretty(b, v, 0);
            return b.toString();
        }

        static void pretty(StringBuilder b, Object v, int indent) {
            String flat = flat(v);
            boolean typeRef = v instanceof Map<?, ?> m && m.get("kind") instanceof String k && TYPE_REF_KINDS.contains(k);
            if (typeRef || flat.length() + indent * 2 <= 100 || !(v instanceof Map || v instanceof List)) {
                b.append(flat);
                return;
            }
            String pad = "  ".repeat(indent + 1);
            if (v instanceof Map<?, ?> m) {
                b.append("{\n");
                int i = 0;
                for (Map.Entry<?, ?> e : m.entrySet()) {
                    b.append(pad).append(quote((String) e.getKey())).append(": ");
                    pretty(b, e.getValue(), indent + 1);
                    b.append(++i < m.size() ? ",\n" : "\n");
                }
                b.append("  ".repeat(indent)).append('}');
            } else {
                List<?> l = (List<?>) v;
                b.append("[\n");
                for (int i = 0; i < l.size(); i++) {
                    b.append(pad);
                    pretty(b, l.get(i), indent + 1);
                    b.append(i + 1 < l.size() ? ",\n" : "\n");
                }
                b.append("  ".repeat(indent)).append(']');
            }
        }

        static String flat(Object v) {
            if (v == null) return "null";
            if (v instanceof String s) return quote(s);
            if (v instanceof Boolean || v instanceof Integer || v instanceof Long) return v.toString();
            StringBuilder b = new StringBuilder();
            if (v instanceof Map<?, ?> m) {
                b.append('{');
                int i = 0;
                for (Map.Entry<?, ?> e : m.entrySet()) {
                    if (i++ > 0) b.append(", ");
                    b.append(quote((String) e.getKey())).append(": ").append(flat(e.getValue()));
                }
                return b.append('}').toString();
            }
            if (v instanceof List<?> l) {
                b.append('[');
                for (int i = 0; i < l.size(); i++) {
                    if (i > 0) b.append(", ");
                    b.append(flat(l.get(i)));
                }
                return b.append(']').toString();
            }
            throw new IllegalArgumentException("not JSON: " + v.getClass());
        }

        static String quote(String s) {
            StringBuilder b = new StringBuilder("\"");
            for (char c : s.toCharArray()) {
                switch (c) {
                    case '"' -> b.append("\\\"");
                    case '\\' -> b.append("\\\\");
                    case '\n' -> b.append("\\n");
                    case '\r' -> b.append("\\r");
                    case '\t' -> b.append("\\t");
                    default -> {
                        if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                        else b.append(c);
                    }
                }
            }
            return b.append('"').toString();
        }
    }
}
