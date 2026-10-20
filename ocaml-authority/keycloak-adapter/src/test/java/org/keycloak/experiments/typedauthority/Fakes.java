package org.keycloak.experiments.typedauthority;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Proxy;
import java.util.HashMap;
import java.util.Map;

/**
 * Interface fakes without a mocking library. Stubs are matched by method name. A method that is neither
 * stubbed nor a default method throws, so a test fails loudly when the adapter reads state the test did not
 * set up (the fakes double as a list of the Keycloak state the adapter touches).
 */
final class Fakes {

    @FunctionalInterface
    interface Answer {
        Object answer(Object[] args) throws Throwable;
    }

    private Fakes() {
    }

    /** {@code stubs} alternates method name and result; a result that is an {@link Answer} is called per invocation. */
    static <T> T fake(Class<T> type, Object... stubs) {
        Map<String, Object> answers = new HashMap<>();
        for (int i = 0; i < stubs.length; i += 2) {
            answers.put((String) stubs[i], stubs[i + 1]);
        }
        InvocationHandler handler = (proxy, method, args) -> {
            String name = method.getName();
            if (answers.containsKey(name)) {
                Object result = answers.get(name);
                return result instanceof Answer answer ? answer.answer(args == null ? new Object[0] : args) : result;
            }
            switch (name) {
                case "equals":
                    return proxy == args[0];
                case "hashCode":
                    return System.identityHashCode(proxy);
                case "toString":
                    return type.getSimpleName() + answers.getOrDefault("getName", answers.getOrDefault("getId", ""));
                default:
                    if (method.isDefault()) {
                        return InvocationHandler.invokeDefault(proxy, method, args);
                    }
                    throw new UnsupportedOperationException(type.getSimpleName() + "." + name + " is not stubbed");
            }
        };
        return type.cast(Proxy.newProxyInstance(Fakes.class.getClassLoader(), new Class<?>[] {type}, handler));
    }
}
