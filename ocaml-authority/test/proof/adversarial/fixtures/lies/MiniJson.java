package adv.lies;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Support, not part of the extracted slice. Stands in for JsonSerialization.readValue(bytes, Map.class): it
 * returns what Jackson returns for the claim token {"mandate": [7], "effect": "produce:organization"}.
 */
final class MiniJson {

    private MiniJson() {
    }

    static Object readValue(String json, Class<?> type) {
        Map<String, Object> decoded = new LinkedHashMap<>();
        decoded.put("mandate", List.of(7));
        decoded.put("effect", "produce:organization");
        return decoded;
    }
}
