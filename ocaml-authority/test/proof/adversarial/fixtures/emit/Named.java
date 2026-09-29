package adv.emit;

/** Attack 4 (extra): a setter whose value type differs from its getter's. */
public interface Named {

    String getName();

    void setName(Integer name);
}
