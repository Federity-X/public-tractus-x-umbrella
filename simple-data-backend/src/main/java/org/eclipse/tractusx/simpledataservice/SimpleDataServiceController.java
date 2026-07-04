/********************************************************************************
 * Copyright (c) 2022,2024 Bayerische Motoren Werke Aktiengesellschaft (BMW AG)
 * Copyright (c) 2021,2026 Contributors to the Eclipse Foundation
 * Copyright (c) 2026 Catena-X Automotive Network e.V.
 *
 * See the NOTICE file(s) distributed with this work for additional
 * information regarding copyright ownership.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ********************************************************************************/
package org.eclipse.tractusx.simpledataservice;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

/**
 * Stores submodel documents in a JPA repository. With the embedded H2 default the data
 * is in-memory (lost on restart, matching the original behaviour); pointing
 * {@code spring.datasource.*} at a PostgreSQL instance makes it durable across restarts.
 */
@RestController
@RequestMapping
@RequiredArgsConstructor
@Slf4j
public class SimpleDataServiceController {

    private final SubmodelDataRepository repository;
    private final ObjectMapper objectMapper = new ObjectMapper();

    @PostMapping("/{id}")
    public void addData(@PathVariable final String id, @RequestBody final Object payload) {
        log.info("Adding data for id '{}'", id);
        try {
            repository.save(new SubmodelData(id, objectMapper.writeValueAsString(payload)));
        } catch (JsonProcessingException e) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Payload is not serializable: " + e.getMessage());
        }
    }

    @GetMapping({"/{id}", "/{id}/$value"})
    public Object getData(@PathVariable final String id) {
        SubmodelData entity = repository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "No data found with id '%s'".formatted(id)));
        log.info("Returning data for id '{}'", id);
        try {
            return objectMapper.readValue(entity.getPayload(), Object.class);
        } catch (JsonProcessingException e) {
            throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "Stored payload is corrupt: " + e.getMessage());
        }
    }

    @DeleteMapping("/{id}")
    public void deleteData(@PathVariable final String id) {
        if (!repository.existsById(id)) {
            throw new ResponseStatusException(HttpStatus.NOT_FOUND, "No data found with id '%s'".formatted(id));
        }
        log.info("Deleting data for id '{}'", id);
        repository.deleteById(id);
    }
}
