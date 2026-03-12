/**
 * Invocable action to read from Data Cloud configured sources using a static resource JSON,
 * filtered by a list of source ids, and return a Flow-friendly collection of field/value pairs
 * aggregated per source id.
 *
 * Example static resource JSON:
 {
  "target": "Account",
  "Queries": [
    {
      "source": "ssot__Account__dlm",
      "id": "ssot__Id__c",
      "fields": {
        "ssot__Name__c": "Name",
        "ssot__Description__c": "Description"
      }
    },
    {
      "source": "ssot__ContactPointAddress__dlm",
      "id": "ssot__Id__c",
      "fields": {
        "ssot__AddressLine1__c": "BillingAddressLine1",
        "ssot__CityId__c": "BillingCity",
        "ssot__StateProvinceId__c": "BillingState",
        "ssot__PostalCodeId__c": "BillingPostalCode",
        "ssot__CountryId__c": "BillingCountry"
      }
    }
  ]
}
 */
public with sharing class SnapDataCloudReader {

    // ---------------------------
    // Invocable request & response types
    // ---------------------------

    public class Request {
        @InvocableVariable(required=true label='Source Ids' description='List of source id values to filter by')
        public List<String> sourceIds;

        @InvocableVariable(required=true label='Static Resource Name' description='Name of a static resource containing JSON configuration')
        public String staticResourceName;
    }

    public class FieldValue {
        @InvocableVariable(label='Target Field API Name')
        public String targetFieldApiName;

        @InvocableVariable(label='Value (String)')
        public String value;

        @InvocableVariable(label='Source Field API Name')
        public String sourceFieldApiName;

        @InvocableVariable(label='Source Object API Name')
        public String sourceObjectApiName;
    }

    public class Row {
        @InvocableVariable(label='Source Id')
        public String sourceId;

        @InvocableVariable(label='Field Values')
        public List<FieldValue> values;

        // Optional convenience: serialized map of { targetFieldApiName -> value }
        @InvocableVariable(label='Values JSON')
        public String valuesJson;
    }

    public class Result {
        @InvocableVariable(label='Target Object')
        public String targetObject;

        @InvocableVariable(label='Rows (by Source Id)')
        public List<Row> rows;
    }

    // ---------------------------
    // Config binding classes
    // ---------------------------

    private class Config {
        public String target;
        public List<QueryDef> Queries;
    }

    private class QueryDef {
        public String source;              // e.g., ssot__Account__dlm
        public String id;                  // e.g., ssot__Id__c
        public Map<String, String> fields; // sourceField -> targetField
    }

    // ---------------------------
    // Invocable entry point
    // ---------------------------

    @InvocableMethod(
        label='Read Data Cloud (Config-driven)'
        description='Reads Data Cloud objects per JSON static resource config, filtered by Source Ids. Returns per-id field/value pairs aggregated across queries.'
        callout=false
    )
    public static List<Result> run(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<Result>();
        }

        List<Result> out = new List<Result>();
        for (Request req : requests) {
            out.add(handleOneRequest(req));
        }
        return out;
    }

    // ---------------------------
    // Core handler per request
    // ---------------------------

    private static Result handleOneRequest(Request req) {
        if (req == null) throw new AuraHandledException('Request cannot be null.');
        if (String.isBlank(req.staticResourceName)) throw new AuraHandledException('Static resource name is required.');
        if (req.sourceIds == null || req.sourceIds.isEmpty()) {
            // Return empty; this is not an error for Flow behavior.
            Result emptyRes = new Result();
            emptyRes.targetObject = null;
            emptyRes.rows = new List<Row>();
            return emptyRes;
        }

        Config cfg = loadConfig(req.staticResourceName);

        // Aggregate rows per SourceId across all queries in the config
        Map<String, Row> rowsById = new Map<String, Row>();

        // For governor safety, query in chunks; also prevent empty field lists
        for (QueryDef qd : cfg.Queries) {
            if (qd == null) continue;
            if (String.isBlank(qd.source) || String.isBlank(qd.id) || qd.fields == null || qd.fields.isEmpty()) {
                continue;
            }

            // Build field list: include the id field plus all source fields used in mapping
            Set<String> fieldSet = new Set<String>();
            fieldSet.add(qd.id);
            fieldSet.addAll(qd.fields.keySet());

            // SOQL fields string
            String fieldsCsv = String.join(new List<String>(fieldSet), ',');

            // Chunk source ids for the IN clause
            List<List<String>> chunks = chunk(req.sourceIds, 2000);

            for (List<String> chunkIds : chunks) {
                if (chunkIds.isEmpty()) continue;

                // Bind variable (allowed in Database.query dynamic SOQL)
                Set<String> bindIds = new Set<String>(chunkIds);

                String soql =
                    'SELECT ' + fieldsCsv +
                    ' FROM ' + qd.source +
                    ' WHERE ' + qd.id + ' IN :bindIds';

                List<SObject> recs;
                try {
                    recs = Database.query(soql);
                } catch (Exception ex) {
                    // If schema varies or object not accessible, bubble up a meaningful message
                    throw new AuraHandledException(
                        'Query failed for source [' + qd.source + '] id field [' + qd.id + ']. ' + ex.getMessage()
                    );
                }

                // Process records
                for (SObject sob : recs) {
                    Object idObj = sob.get(qd.id);
                    String idVal = (idObj == null) ? null : String.valueOf(idObj);
                    if (String.isBlank(idVal)) {
                        continue;
                    }

                    Row row = rowsById.get(idVal);
                    if (row == null) {
                        row = new Row();
                        row.sourceId = idVal;
                        row.values = new List<FieldValue>();
                        rowsById.put(idVal, row);
                    }

                    // Accumulate mapped field values
                    Map<String, String> latestValues = new Map<String, String>(); // to also build valuesJson
                    for (String sourceField : qd.fields.keySet()) {
                        String targetField = qd.fields.get(sourceField);
                        Object raw = sob.get(sourceField);
                        if (raw == null) {
                            continue; // skip nulls, do not overwrite existing values
                        }

                        String strVal = stringifyValue(raw);

                        FieldValue fv = new FieldValue();
                        fv.targetFieldApiName = targetField;
                        fv.value = strVal;
                        fv.sourceFieldApiName = sourceField;
                        fv.sourceObjectApiName = qd.source;
                        row.values.add(fv);

                        // In the JSON view, keep "last non-null wins" behavior
                        latestValues.put(targetField, strVal);
                    }

                    // Refresh valuesJson with a merged view across all passes
                    // To merge: reconstruct map from existing values + latestValues
                   // Map<String, String> merged = new Map<String, String>();
                   Map<String, Object> merged = new Map<String, Object>();
                    if (!String.isBlank(row.valuesJson)) {
                        try {
                            merged.putAll((Map<String, Object>) JSON.deserializeUntyped(row.valuesJson));
                            // Convert Object->String
                            Map<String, String> casted = new Map<String, String>();
                            for (String k : merged.keySet()) casted.put(k, String.valueOf(merged.get(k)));
                            merged = casted;
                        } catch (Exception ignore) {}
                    }
                    merged.putAll(latestValues);
                    row.valuesJson = JSON.serialize(merged);
                }
            }
        }

        Result res = new Result();
        res.targetObject = cfg.target;
        res.rows = new List<Row>(rowsById.values());
        return res;
    }

    // ---------------------------
    // Helpers
    // ---------------------------

    private static Config loadConfig(String staticResourceName) {
        // Load by name at runtime (cannot use Resource.name when name is dynamic)
        StaticResource sr = [
            SELECT Body
            FROM StaticResource
            WHERE Name = :staticResourceName
            LIMIT 1
        ];
        if (sr == null || sr.Body == null) {
            throw new AuraHandledException('Static resource "' + staticResourceName + '" not found or has no body.');
        }
        String jsonCfg = sr.Body.toString();

        Config cfg;
        try {
            cfg = (Config) JSON.deserialize(jsonCfg, Config.class);
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid JSON in static resource "' + staticResourceName + '": ' + ex.getMessage());
        }
        if (cfg == null || String.isBlank(cfg.target) || cfg.Queries == null || cfg.Queries.isEmpty()) {
            throw new AuraHandledException('Config must include "target" and a non-empty "Queries" array.');
        }
        return cfg;
    }

    private static List<List<String>> chunk(List<String> items, Integer size) {
        List<List<String>> out = new List<List<String>>();
        if (items == null || items.isEmpty()) return out;
        if (size == null || size <= 0) size = 2000;
        //Integer i = 0;
        //while (i < items.size()) {
        //    Integer endA = Math.min(i + size, items.size());
        //    out.add(items.subList(i, endA));
         //   i = endA;
        //}
        out.add(items);
        return out;
    }

    private static String stringifyValue(Object raw) {
        if (raw == null) return null;
        if (raw instanceof Date) return ((Date) raw).format();
        if (raw instanceof Datetime) return ((Datetime) raw).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        if (raw instanceof Decimal) return String.valueOf((Decimal) raw);
        if (raw instanceof Integer) return String.valueOf((Integer) raw);
        if (raw instanceof Long) return String.valueOf((Long) raw);
        if (raw instanceof Double) return String.valueOf((Double) raw);
        if (raw instanceof Boolean) return ((Boolean) raw) ? 'true' : 'false';
        if (raw instanceof Id) return String.valueOf((Id) raw);
        if (raw instanceof String) return (String) raw;
        // Fallback for other types (incl. external object types): JSON-serialize
        return JSON.serialize(raw);
    }
}