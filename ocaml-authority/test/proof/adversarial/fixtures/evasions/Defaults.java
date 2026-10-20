package adv.evasions;

import java.util.function.Supplier;

/** Attack 2g: default methods and null literals inside and outside lambdas. */
public interface Defaults {

    default Supplier<String> lazy() {
        return () -> null;
    }

    default String direct() {
        Runnable ignored = () -> { };
        return null;
    }

    @org.example.ext.Nonnull
    default String castNull() {
        return (String) null;
    }

    @org.example.ext.Nonnull
    default String switchNull(int k) {
        return switch (k) {
            case 0 -> null;
            default -> "x";
        };
    }

    @org.example.ext.Nonnull
    default String yieldNull(int k) {
        return switch (k) {
            case 0: yield null;
            default: yield "x";
        };
    }

    @org.example.ext.Nonnull
    default String viaLambda() {
        Supplier<String> none = () -> null;
        return none.get();
    }

    default String localVar() {
        var value = (String) null;
        return value;
    }
}
