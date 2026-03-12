/**
 * Invocable action to read from Data Cloud configured sources using a static resource JSON,
 * filtered by a list of source ids, aggregate field values, WRITE to the target SObject,
 * and log errors to Data_Cloud_Logs__c.
 *
 * Optional config extension:
 * {
 *   "target": "Account",
 *   "upsertField": "External_Id__c",         // OPTIONAL: if present, performs UPSERT on this field. Use "Id" to upsert by Id.
 *   "Queries": [ ... ]
 * }
 *
 *
 *
 * Example static resource JSON:
 {
  "target": "Account",
  "upsertField": "External_Id__c", #optional
  "Queries": [
    {
      "source": "ssot__Account__dlm",
      "id": "ssot__Id__c",
      "fields": {
        "ssot__Name__c": "Name",
        "ssot__Description__c": "Description"
      },
      "lookups":{        #optional
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
       },
       "lookups":{          #optional  
      }
    }
  ]
}
 *
 *
 *
 * Error logs (if object exists): Data_Cloud_Logs__c with fields:
 *   - Source__c (Text): target SObject API name (e.g., "Account")
 *   - Source_Id__c (Text): the sourceId whose write failed
 *   - Payload__c (Long Text): JSON payload attempted
 *   - Error_Message__c (Long Text): error details
 */
public with sharing class SnapDataCloudSync {

    // ---------------------------
    // Invocable request & response types (kept so Flow can still consume the read results)
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

        // Convenience: serialized map of { targetFieldApiName -> value }
        @InvocableVariable(label='Values JSON')
        public String valuesJson;

        // (Optional) capture target record Id if write succeeded
        @InvocableVariable(label='Created/Upserted Record Id')
        public String targetRecordId;
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
        public String upsertField;           // optional
        public List<QueryDef> Queries;
    }

    private class QueryDef {
        public String source;              // e.g., ssot__Account__dlm
        public String id;                  // e.g., ssot__Id__c
        public Map<String, String> fields; // sourceField -> targetField
    }

    // ---------------------------
    // Logging config (adjust field API names if different in your org)
    // ---------------------------
    private static final String LOG_OBJECT_API = 'Data_Cloud_Logs__c';
    private static final String LOG_SOURCE_FIELD = 'Source__c';
    private static final String LOG_SOURCEID_FIELD = 'Source_Id__c';
    private static final String LOG_PAYLOAD_FIELD = 'Payload__c';
    private static final String LOG_ERROR_FIELD = 'Error_Message__c';

    // ---------------------------
    // Invocable entry point
    // ---------------------------

    @InvocableMethod(
        label='Read Data Cloud/Write CRM (Config-driven)'
        description='Reads Data Cloud objects per JSON static resource config, writes to CRMfiltered by Source Ids. Returns per-id field/value pairs aggregated across queries.'
        callout=false
    )
    public static List<Result> run(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<Result>();
        }

        List<Result> out = new List<Result>();
        for (Request req : requests) {
            try {
                out.add(handleOneRequest(req));
            } catch (Exception ex) {
                // If top-level error occurs, capture a single log record for visibility
                logOne(null, null, null, 'Top-level failure: ' + ex.getMessage());
                // Re-throw so Flow/Admin sees the failure if desired.
                throw ex;
            }
        }
        return out;
    }

    // ---------------------------
    // Core handler per request: read, aggregate, write, log
    // ---------------------------

    private static Result handleOneRequest(Request req) {
        if (req == null) throw new AuraHandledException('Request cannot be null.');
        if (String.isBlank(req.staticResourceName)) throw new AuraHandledException('Static resource name is required.');

        // Empty input is a no-op (Flow-friendly)
        if (req.sourceIds == null || req.sourceIds.isEmpty()) {
            Result emptyRes = new Result();
            emptyRes.targetObject = null;
            emptyRes.rows = new List<Row>();
            return emptyRes;
        }

        Config cfg = loadConfig(req.staticResourceName);
        Map<Id,Id> mapRef = loadRecordTypes(cfg.target);
        // 1) READ & AGGREGATE
        Map<String, Row> rowsById = fetchAndAggregate(cfg, req.sourceIds, mapRef);

        // 2) WRITE TO TARGET (Insert or Upsert)
        writeToTarget(cfg, rowsById);

        // 3) Return results (with any created/updated Ids filled in)
        Result res = new Result();
        res.targetObject = cfg.target;
        res.rows = new List<Row>(rowsById.values());
        return res;
    }

    // ---------------------------
    // Phase 1: Read & Aggregate
    // ---------------------------

    private static Map<String, Row> fetchAndAggregate(Config cfg, List<String> allSourceIds, Map<Id, Id> mapRef) {
        Map<String, Row> rowsById = new Map<String, Row>();

        for (QueryDef qd : cfg.Queries) {
            if (qd == null) continue;
            if (String.isBlank(qd.source) || String.isBlank(qd.id) || qd.fields == null || qd.fields.isEmpty()) {
                continue;
            }

            Set<String> fieldSet = new Set<String>();
            fieldSet.add(qd.id);
            fieldSet.addAll(qd.fields.keySet());
            String fieldsCsv = String.join(new List<String>(fieldSet), ',');

            for (List<String> chunkIds : chunk(allSourceIds, 2000)) {
                if (chunkIds.isEmpty()) continue;

                Set<String> bindIds = new Set<String>(chunkIds);
                String soql =
                    'SELECT ' + fieldsCsv +
                    ' FROM ' + qd.source +
                    ' WHERE ' + qd.id + ' IN :bindIds';

                List<SObject> recs;
                try {
                    recs = Database.query(soql);
                } catch (Exception ex) {
                    // Log query failure; continue other queries
                    logOne(/*source*/ qd.source, /*sourceId*/ null, /*payload*/ fieldsCsv, /*err*/ 'Query failed: ' + ex.getMessage());
                    continue;
                }

                for (SObject sob : recs) {
                    Object idObj = sob.get(qd.id);
                    String idVal = (idObj == null) ? null : String.valueOf(idObj);
                    if (String.isBlank(idVal)) continue;

                    Row row = rowsById.get(idVal);
                    if (row == null) {
                        row = new Row();
                        row.sourceId = idVal;
                        row.values = new List<FieldValue>();
                        row.valuesJson = JSON.serialize(new Map<String, String>());
                        rowsById.put(idVal, row);
                    }

                    // Build latest values for this record from this query
                    Map<String, String> latest = new Map<String, String>();
                    for (String sourceField : qd.fields.keySet()) {
                        String targetField = qd.fields.get(sourceField);
                        Object raw = sob.get(sourceField);
                        if (raw == null) continue;

                        String strVal = stringifyValue(raw);
                        
                        //**********Swtich Out Snap RecordType for ADI RT */
                        if (targetField == 'RecordTypeId')  {
                            if(mapRef.containsKey(Id.valueOf(strVal))){
                                strVal = String.valueOf(mapRef.get(Id.valueOf(strVal)));
                            }

                        }

                            

                        /************************************************ */
                        FieldValue fv = new FieldValue();
                        fv.targetFieldApiName = targetField;
                        fv.value = strVal;
                        fv.sourceFieldApiName = sourceField;
                        fv.sourceObjectApiName = qd.source;
                        row.values.add(fv);

                        latest.put(targetField, strVal);
                    }

                    // Merge into valuesJson (last non-null wins)
                    Map<String, Object> merged = new Map<String, Object>();
                    try {
                        merged.putAll((Map<String, Object>) JSON.deserializeUntyped(row.valuesJson));
                    } catch (Exception ignore) {}
                    for (String k : latest.keySet()) merged.put(k, latest.get(k));
                    row.valuesJson = JSON.serialize(merged);
                }
            }
        }

        return rowsById;
    }

    // ---------------------------
    // Phase 2: Write to Target and Log Errors
    // ---------------------------

    private static void writeToTarget(Config cfg, Map<String, Row> rowsById) {
        if (rowsById.isEmpty()) return;

        // Describe target
        Schema.SObjectType tgtType = Schema.getGlobalDescribe().get(cfg.target);
        if (tgtType == null) {
            logOne(cfg.target, null, null, 'Target object "' + cfg.target + '" not found.');
            throw new AuraHandledException('Target object "' + cfg.target + '" not found.');
        }

        Schema.DescribeSObjectResult tgtDescribe = tgtType.getDescribe();
        Map<String, Schema.SObjectField> tgtFieldTokens = tgtDescribe.fields.getMap(); // name -> SObjectField
        Map<String, Schema.DescribeFieldResult> tgtFieldDescribes = new Map<String, Schema.DescribeFieldResult>();
        for (String f : tgtFieldTokens.keySet()) {
            tgtFieldDescribes.put(f, tgtFieldTokens.get(f).getDescribe());
        }

        List<SObject> toDml = new List<SObject>();
        // Keep alignment lists to map SaveResult index back to sourceId & payload
        List<String> sourceIdsForDml = new List<String>();
        List<String> payloadsForDml = new List<String>();

        for (Row row : rowsById.values()) {
            // Parse valuesJson (preferred de-duplicated map of target -> value)
            Map<String, Object> vals = new Map<String, Object>();
            try {
                vals.putAll((Map<String, Object>) JSON.deserializeUntyped(row.valuesJson));
            } catch (Exception ex) {
                logOne(cfg.target, row.sourceId, row.valuesJson, 'Could not parse valuesJson: ' + ex.getMessage());
                continue; // skip this row
            }

            // Build a new target record
            SObject targetRec = tgtType.newSObject();

            // Convert & set fields
            Boolean hadConversionError = false;
            for (String targetField : vals.keySet()) {
                Object raw = vals.get(targetField);
                if (raw == null) continue;

                Schema.DescribeFieldResult dfr = tgtFieldDescribes.get(targetField);
                if (dfr == null) {
                    // Unknown field; log and skip
                    logOne(cfg.target, row.sourceId, row.valuesJson, 'Target field not found: ' + targetField);
                    continue;
                }

                try {
                    //Object coerced = coerceToFieldType(String.valueOf(raw), dfr);
                    //targetRec.put(targetField, coerced);
                    //
                    Schema.DisplayType dt = dfr.getType();

					// Convert to String using .name()
					String typeAsString1 = dt.name();
   
                    if (typeAsString1=='BOOLEAN') {
                        boolean t = true;
                    	boolean f = false;
                        if(raw=='true') {targetRec.put(targetField, t);}
                        else {targetRec.put(targetField, f);}
                    }else if(typeAsString1=='DATE') {
                        String jsonDate = (String) raw;
                        List<String> parts = jsonDate.split('/');
                        Date newDate = Date.newInstance(Integer.valueOf(parts[2]), Integer.valueOf(parts[0]), Integer.valueOf(parts[1]));
                        targetRec.put(targetField, newDate);
                    } else if(typeAsString1=='DATETIME') {
                        String jsonDate = (String) raw;
                        String formattedDate = jsonDate.replace('T', ' ').removeEnd('Z');
                        Datetime newDatetime = DateTime.valueOf(formattedDate);
                        targetRec.put(targetField, newDatetime);
                    }else if(typeAsString1=='DOUBLE') {
                      
                        String rawStr = String.valueOf(raw);
                        String cleanedString = rawStr.replaceAll(',', '');
                        Decimal dec = Decimal.valueOf(cleanedString);
                      
                        targetRec.put(targetField, dec);
                    }else if(typeAsString1=='ID') {
                        Id newId = Id.valueOf((String) raw);
                        targetRec.put(targetField, newId);
                    }else{
                        targetRec.put(targetField, raw);}
                } catch (Exception ex) {
                    hadConversionError = true;
                    logOne(cfg.target, row.sourceId, row.valuesJson,
                           'Type conversion failed for field ' + targetField + ': ' + ex.getMessage());
                }
            }

            if (hadConversionError) {
                // We still attempt DML with the remaining valid fields; if you prefer to skip entirely, uncomment:
                // continue;
            }

            toDml.add(targetRec);
            sourceIdsForDml.add(row.sourceId);
            payloadsForDml.add(row.valuesJson);
        }

        if (toDml.isEmpty()) return;

        // Perform DML (insert or upsert)
        Database.SaveResult[] sr;
        try {
            if (!String.isBlank(cfg.upsertField)) {
                Schema.SObjectField extField;
                Schema.SObjectField token = tgtFieldTokens.get(cfg.upsertField);
                if (token != null) {
                    extField = token;
                } else if (cfg.upsertField == 'Id') {
                    // Apex requires SObjectField token; emulate via Id by just using Database.upsert without token if Id set.
                    // But we don't have Id values typically; log a warning:
                    logOne(cfg.target, null, null, 'Upsert field set to Id but no Id values are provided; falling back to INSERT.');
                   
                    sr = Database.insert(toDml, /*allOrNone*/ false);
                    // Map SaveResults below
                    mapSaveResultsBack(sr, rowsById, sourceIdsForDml, payloadsForDml);
                    return;
                } else {
                    logOne(cfg.target, null, null, 'Upsert field "' + cfg.upsertField + '" not found on ' + cfg.target + '. Falling back to INSERT.');
                    sr = Database.insert(toDml, /*allOrNone*/ false);
                    mapSaveResultsBack(sr, rowsById, sourceIdsForDml, payloadsForDml);
                    return;
                }
               
                Database.insert(toDml, /*allOrNone*/ false);
                //sr = Database.upsert(toDml, extField, /*allOrNone*/ false);
            } else {
  
                sr = Database.insert(toDml, /*allOrNone*/ false);
               
            }
        } catch (Exception ex) {
            // Catastrophic DML failure (rare when allOrNone=false)
            logOne(cfg.target, null, null, 'Bulk DML failed: ' + ex.getMessage());
            throw ex;
        }

        // Map SaveResults back to rows and log individual failures
        mapSaveResultsBack(sr, rowsById, sourceIdsForDml, payloadsForDml);
    }

    private static void mapSaveResultsBack(
        Database.SaveResult[] sr,
        Map<String, Row> rowsById,
        List<String> sourceIdsForDml,
        List<String> payloadsForDml
    ) {
        for (Integer i = 0; i < sr.size(); i++) {
            Database.SaveResult one = sr[i];
            String sourceId = sourceIdsForDml[i];
            String payload = payloadsForDml[i];

            if (one.isSuccess()) {
                // Stamp created/upserted Id back onto the row for Flow usage
                Row r = rowsById.get(sourceId);
                if (r != null && one.getId() != null) {
                    r.targetRecordId = one.getId();
                }
            } else {
                String errMsg = joinErrors(one.getErrors());
                logOne(/*source*/ 'WRITE:' + getTargetFromRows(rowsById, sourceId), /*sourceId*/ sourceId, /*payload*/ payload, /*err*/ errMsg);
            }
        }
    }

    private static String getTargetFromRows(Map<String, Row> rowsById, String sourceId) {
        // Placeholder target name for log source context. We cannot easily access cfg.target here;
        // keep this as a simple constant or return empty; logs already include payload & id.
        return 'Target';
    }

    private static String joinErrors(Database.Error[] errors) {
        List<String> parts = new List<String>();
        for (Database.Error e : errors) {
            parts.add(e.getStatusCode() + ': ' + e.getMessage());
        }
        return String.join(parts, ' | ');
    }

    // ---------------------------
    // Logging helper (safe if object/fields absent)
    // ---------------------------

    private static void logOne(String source, String sourceId, String payload, String errMsg) {
        try {
            Map<String, Schema.SObjectType> g = Schema.getGlobalDescribe();
            if (!g.containsKey(LOG_OBJECT_API)) return; // log object not present; skip

            Schema.SObjectType logType = g.get(LOG_OBJECT_API);
            Schema.DescribeSObjectResult d = logType.getDescribe();
            Map<String, Schema.SObjectField> f = d.fields.getMap();

            SObject rec = logType.newSObject();
            if (f.containsKey(LOG_SOURCE_FIELD))  rec.put(LOG_SOURCE_FIELD, source);
            if (f.containsKey(LOG_SOURCEID_FIELD)) rec.put(LOG_SOURCEID_FIELD, sourceId);
            if (f.containsKey(LOG_PAYLOAD_FIELD))  rec.put(LOG_PAYLOAD_FIELD, payload);
            if (f.containsKey(LOG_ERROR_FIELD))    rec.put(LOG_ERROR_FIELD, errMsg);

            insert rec;
        } catch (Exception ignore) {
            // Never let logging cause failures. Intentionally swallowed.
        }
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

    private static Map<Id,Id> loadRecordTypes(String targetObject) {
		 // --------------------------------------------
		// 1. First map<Id, String>
		//    Key   = Id__c (Id type)
		//    Value = DeveloperName__c (String)
		// --------------------------------------------
		// --------------------------------------------
		// 2. Second map<String, Id>
		//    Key   = DeveloperName__c
		//    Value = Id__c
		// --------------------------------------------
		Map<Id, String> mapSnapRT = new Map<Id, String>();
		Map<String, Id> mapADIRT = new Map<String, Id>();
		for (RecordType_Home__dlm rec : [
			SELECT Id__c, DeveloperName__c, DataSource__c
			FROM RecordType_Home__dlm
			WHERE SobjectType__c = :targetObject
		]) {
			if (rec.DataSource__c != 'Salesforce_Home') {
				mapSnapRT.put(rec.Id__c, rec.DeveloperName__c);
			}
			if (rec.DataSource__c == 'Salesforce_Home') {
				mapADIRT.put(rec.DeveloperName__c, rec.Id__c);
			}
		}
		// --------------------------------------------
		// 3. Third map<Id, Id>
		//    Key   = Id__c from first map
		//    Value = matching Id__c from second map 
		//            using DeveloperName__c as the link
		// --------------------------------------------
		Map<Id, Id> mapLookup = new Map<Id, Id>();
		
		for (Id firstKey : mapSnapRT.keySet()) {
			String devName = mapSnapRT.get(firstKey);
		
			// If DeveloperName from mapSnapRT exists as a key in mapADIRT
			if (mapADIRT.containsKey(devName)) {
				mapLookup.put(firstKey, mapADIRT.get(devName));
			}
		}
        return mapLookup;
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