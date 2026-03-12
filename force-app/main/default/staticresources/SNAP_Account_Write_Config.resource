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
