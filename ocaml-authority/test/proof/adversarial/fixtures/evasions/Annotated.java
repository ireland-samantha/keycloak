package adv.evasions;

/** Attack 2f: annotations called Nullable / Nonnull / NotNull from different packages. */
public interface Annotated {

    @org.example.ext.Nonnull
    String customNonnull();

    @org.example.validation.NotNull
    String validationNotNull();

    @org.example.ext.Nullable
    String customNullable();

    @org.example.ext.Nullable
    @org.example.ext.Nonnull
    String both();

    java.lang.@org.example.ext.Nonnull String typeUseNonnull();

    @org.example.ext.Nonnull
    default String nullAtRuntime() {
        String none = null;
        return none;
    }
}
