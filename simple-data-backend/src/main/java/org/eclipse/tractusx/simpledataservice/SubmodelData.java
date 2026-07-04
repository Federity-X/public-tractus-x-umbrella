/********************************************************************************
 * Copyright (c) 2026 Contributors to the Eclipse Foundation
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

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/**
 * A single stored submodel document, keyed by its id. The payload is the raw JSON
 * serialized to a String so the store is DB-agnostic (works on the embedded H2 default
 * and on PostgreSQL when a datasource is configured for a durable deployment).
 */
@Entity
@Table(name = "submodel_data")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
public class SubmodelData {

    @Id
    private String id;

    // Large VARCHAR keeps this portable across H2 and PostgreSQL (avoids the
    // Hibernate @Lob/CLOB-vs-oid mismatch); submodel documents are small.
    @Column(length = 1_048_576)
    private String payload;
}
