package org.keycloak.experiments.typedauthority;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * Runs {@code <kernel> eval} as a child process: request on stdin, decision on stdout (wire-format.md).
 * Returns only a well-formed decision/v1 document answering this request; everything else is a {@link Failure}.
 */
final class Kernel {

    static final int MAX_DECISION_BYTES = 4 * 1024 * 1024;
    static final String DECISION_SCHEMA = "typed-authority/decision/v1";
    private static final int STDERR_EXCERPT_BYTES = 2048;

    private static final ExecutorService PIPES = Executors.newCachedThreadPool(task -> {
        Thread thread = new Thread(task, "typed-authority-kernel-pipe");
        thread.setDaemon(true);
        return thread;
    });

    static final class Failure extends Exception {
        Failure(String message) {
            super(message);
        }
    }

    private final Path executable;
    private final Duration timeout;
    private final Path evidenceDir;

    /** {@code executable} and {@code evidenceDir} may be null: no kernel means every decision fails. */
    Kernel(Path executable, Duration timeout, Path evidenceDir) {
        this.executable = executable;
        this.timeout = timeout;
        this.evidenceDir = evidenceDir;
    }

    JsonNode decide(ObjectNode request) throws Failure {
        if (executable == null) {
            throw new Failure("no kernel configured");
        }
        String requestId = request.get("request_id").textValue();
        try {
            byte[] input = Projection.JSON.writeValueAsBytes(request);
            Process process = new ProcessBuilder(executable.toString(), "eval").start();
            Future<?> stdin = PIPES.submit(() -> {
                try (OutputStream out = process.getOutputStream()) {
                    out.write(input);
                }
                return null;
            });
            Future<byte[]> stdout = PIPES.submit(() -> process.getInputStream().readNBytes(MAX_DECISION_BYTES + 1));
            Future<byte[]> stderr = PIPES.submit(() -> drain(process.getErrorStream()));
            try {
                long deadline = System.nanoTime() + timeout.toNanos();
                byte[] output = stdout.get(deadline - System.nanoTime(), TimeUnit.NANOSECONDS);
                if (output.length > MAX_DECISION_BYTES) {
                    throw new Failure("decision exceeds " + MAX_DECISION_BYTES + " bytes");
                }
                if (!process.waitFor(deadline - System.nanoTime(), TimeUnit.NANOSECONDS)) {
                    throw new TimeoutException();
                }
                if (process.exitValue() != 0) {
                    throw new Failure("exit status " + process.exitValue() + ", stderr: "
                            + new String(stderr.get(deadline - System.nanoTime(), TimeUnit.NANOSECONDS), StandardCharsets.UTF_8));
                }
                JsonNode decision = parse(output, requestId);
                if (evidenceDir != null) {
                    Files.createDirectories(evidenceDir);
                    Files.write(evidenceDir.resolve(requestId + ".json"), output, StandardOpenOption.CREATE_NEW);
                }
                // After the evidence: a kernel that answers request_too_large stops reading, and the rest of the write fails.
                stdin.get(deadline - System.nanoTime(), TimeUnit.NANOSECONDS);
                return decision;
            } finally {
                process.destroyForcibly();
            }
        } catch (TimeoutException e) {
            throw new Failure("no decision within " + timeout.toMillis() + " ms, kernel killed");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Failure("interrupted");
        } catch (ExecutionException | IOException e) {
            throw new Failure(e.toString());
        }
    }

    private static JsonNode parse(byte[] output, String requestId) throws Failure {
        JsonNode decision;
        try {
            // Strict UTF-8, as the kernel's own parser: Jackson's byte reader would also take a BOM, UTF-16/32 and overlong forms.
            decision = Projection.JSON.readTree(StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(output)).toString());
        } catch (IOException e) {
            throw new Failure("unparseable decision: " + e.getMessage());
        }
        boolean allow = decision != null && "allow".equals(decision.path("decision").textValue());
        if (decision == null || !DECISION_SCHEMA.equals(decision.path("schema").textValue()) || !decision.path("decision").isTextual()
                || !(requestId.equals(decision.path("request_id").textValue())
                        // A request the kernel cannot decode gets request_id null; such a decision is never "allow".
                        || decision.path("request_id").isNull() && !allow)
                // wire-format.md: authority is present iff the decision is allow, reasons are non-empty iff it is not.
                || allow && (!decision.path("authority").isObject() || !decision.path("reasons").isArray() || !decision.path("reasons").isEmpty())) {
            throw new Failure("output is not a " + DECISION_SCHEMA + " document for request " + requestId);
        }
        return decision;
    }

    /** Reads the stream to its end so the kernel never blocks on it; keeps the first bytes for the log. */
    private static byte[] drain(InputStream in) throws IOException {
        byte[] excerpt = in.readNBytes(STDERR_EXCERPT_BYTES);
        in.transferTo(OutputStream.nullOutputStream());
        return excerpt;
    }
}
