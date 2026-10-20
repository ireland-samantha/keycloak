package adv.lies;

import java.util.List;

/** Attack 1d: generic arrays behind @SuppressWarnings("unchecked"). */
public class Buckets<E> {

    private final E[] items;

    @SuppressWarnings("unchecked")
    public Buckets(int size) {
        this.items = (E[]) new Object[size];
    }

    public E[] toArray() {
        return items;
    }

    @SuppressWarnings("unchecked")
    public static List<String>[] buckets(int size) {
        return (List<String>[]) new List<?>[size];
    }
}
