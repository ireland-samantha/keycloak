package adv.lies;

import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

/** Support, not part of the extracted slice. Prints one line per runtime fact the declared types deny. */
public final class LiesDemo {

    private LiesDemo() {
    }

    public static void main(String[] args) {
        Map<String, List<String>> claims = new PushedClaims("e30").getClaims();
        Object mandate0 = ((List<?>) claims.get("mandate")).get(0);
        System.out.println("LIE 1a getClaims() List<String> element is " + mandate0.getClass().getName());
        Object effect = ((Map<?, ?>) claims).get("effect");
        System.out.println("LIE 1a getClaims() List<String> value is " + effect.getClass().getName());
        System.out.println("LIE 1a typed read: " + thrown(() -> claims.get("mandate").get(0).length()));

        Roles roles = new Roles();
        roles.merge(List.of("a", "b"));
        System.out.println("LIE 1b getNames() List<String> element is " + ((List<?>) roles.getNames()).get(0).getClass().getName());
        System.out.println("LIE 1b typed read: " + thrown(() -> roles.getNames().get(0).length()));

        String act = new DelegatedIdentity("{\"sub\":\"agent\",\"act\":{\"sub\":\"samantha\"}}").getAct();
        System.out.println("LIE 1c getAct() String holds a JSON object: " + act.startsWith("{"));

        System.out.println("LIE 1d toArray() E[] with E=String: " + thrown(() -> new Buckets<String>(1).toArray().length));
        List<String>[] buckets = Buckets.buckets(1);
        Object[] alias = buckets;
        alias[0] = List.of(42);
        System.out.println("LIE 1d buckets() List<String>[] typed read: " + thrown(() -> buckets[0].get(0).length()));

        Lookup lookup = key -> java.util.Optional.empty();
        System.out.println("LIE 1e literalNull() Optional is null: " + (lookup.literalNull() == null));
        System.out.println("LIE 1e indirectNull() Optional is null: " + (lookup.indirectNull() == null));

        FrozenPolicy frozen = new FrozenPolicy();
        System.out.println("LIE 1f setName(String): " + thrown(() -> { frozen.setName("x"); return 0; }));
        System.out.println("LIE 1f getConfig().put: " + thrown(() -> frozen.getConfig().put("k", "v")));

        System.out.println("LIE 1g getNames() Set<String> of {Read, read} has size " + new ScopeNames().getNames().size());
    }

    private static String thrown(Supplier<?> action) {
        try {
            action.get();
            return "no exception";
        } catch (RuntimeException e) {
            return e.getClass().getName();
        }
    }
}
