package adv.evasions;

/** Slice type with behaviour: its encoding cannot be comparable. */
public interface Policy {

    String getName();

    void addScope(Scope scope);
}
