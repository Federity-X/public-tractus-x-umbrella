package org.eclipse.tractusx.simpledataservice;

import org.junit.jupiter.api.Test;
import org.springframework.web.server.ResponseStatusException;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatExceptionOfType;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SimpleDataServiceControllerTest {

    /** Controller wired to a map-backed mock repository so these stay plain unit tests. */
    private SimpleDataServiceController newController() {
        final Map<String, SubmodelData> store = new HashMap<>();
        final SubmodelDataRepository repository = mock(SubmodelDataRepository.class);
        when(repository.save(any(SubmodelData.class))).thenAnswer(i -> {
            final SubmodelData saved = i.getArgument(0);
            store.put(saved.getId(), saved);
            return saved;
        });
        when(repository.findById(anyString())).thenAnswer(i -> Optional.ofNullable(store.get(i.getArgument(0))));
        when(repository.existsById(anyString())).thenAnswer(i -> store.containsKey(i.getArgument(0)));
        doAnswer(i -> {
            store.remove(i.getArgument(0));
            return null;
        }).when(repository).deleteById(anyString());
        return new SimpleDataServiceController(repository);
    }

    @Test
    void shouldStoreData() {
        final SimpleDataServiceController controller = newController();
        final String payload = """
                {
                    "test": "data"
                }
                """;

        controller.addData("test", payload);

        assertThat(controller.getData("test")).isEqualTo(payload);
    }

    @Test
    void shouldOverwriteData() {
        final SimpleDataServiceController controller = newController();
        final String initialPayload = """
                {
                    "test": "initial"
                }
                """;
        final String updatedPayload = """
                {
                    "test": "updated"
                }
                """;

        controller.addData("test", initialPayload);
        controller.addData("test", updatedPayload);

        assertThat(controller.getData("test")).isEqualTo(updatedPayload);
    }

    @Test
    void shouldDeleteData() {
        final SimpleDataServiceController controller = newController();
        final String payload = """
                {
                    "test": "data"
                }
                """;
        controller.addData("test", payload);

        controller.deleteData("test");

        assertThatExceptionOfType(ResponseStatusException.class).isThrownBy(() -> controller.getData("test"));
    }

    @Test
    void shouldThrowNotFoundExceptionOnDelete() {
        final SimpleDataServiceController controller = newController();

        assertThatExceptionOfType(ResponseStatusException.class).isThrownBy(() -> controller.deleteData("test"));
    }

    @Test
    void shouldThrowNotFoundException() {
        final SimpleDataServiceController controller = newController();

        assertThatExceptionOfType(ResponseStatusException.class).isThrownBy(() -> controller.getData("test"));
    }
}
