package adv.evasions;

/** Attack 2 (extra): legal overloads whose parameter types have the same simple name. */
public interface Overloads {

    <T extends Policy> void register(T item);

    <T extends Scope> void register(T item);

    void at(java.util.Date when);

    void at(java.sql.Date when);
}
