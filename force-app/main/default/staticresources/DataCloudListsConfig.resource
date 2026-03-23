{
  "Cases": {
    "query": "SELECT id__c, subject__c FROM Case_SNAPfs__dlm WHERE AccountId__c = 'XX' OR ContactId__c = 'XX'",
    "fieldLabels": {
      "id__c": "Account ID",
      "subject__c": "Subject"
    }
  },
  "CT Training Certifications": {
    "query": "SELECT Name, Certification_Date__c FROM CT_Training_Certifications__dlm WHERE AccountId__c = 'XX' OR ContactId__c = 'XX'",
    "fieldLabels": {
      "Name": "Certification",
      "Certification_Date__c": "Certification Date"
    }
  },
  "Learn Upon Contact Enrollments": {
    "query": "SELECT LearnUponP_Course_Name_c__c, LearnUponP_Date_Enrolled_c__c, LearnUponP_Date_Completed_c__c FROM LearnUponP_LearnUponContactEnrol_SNAPfs__dlm WHERE ContactId__c = 'XX'",
    "fieldLabels": {
       "Name__c":"LearnUponContactEnrollments",
      "LearnUponP_Course_Name_c__c": "Course Name",
      "LearnUponP_Date_Enrolled_c__c": "Date Enrolled",
      "LearnUponP_Date_Completed_c__c":"Date Completed"
    }
  },
  "Local Stores": {
    "query": "SELECT Store_Number__c, City__c, State__c FROM Local_Stores__dlm WHERE AccountId__c = 'XX'",
    "fieldLabels": {
      "Store_Number__c": "Store #",
      "City__c": "City",
      "State__c": "State/Province"
    }
  },
  "Loyalty Rewards": {
    "query": "SELECT Points_Balance__c, Tier__c FROM Loyalty_Rewards__dlm WHERE AccountId__c = 'XX' OR ContactId__c = 'XX'",
    "fieldLabels": {
      "Points_Balance__c": "Points Balance",
      "Tier__c": "Tier"
    }
  },
  "Product Auth Account Rel": {
    "query": "SELECT Product_Name__c, Authorization_Status__c FROM Product_Auth_Account_Rel__dlm WHERE AccountId__c = 'XX'",
    "fieldLabels": {
      "Product_Name__c": "Product",
      "Authorization_Status__c": "Authorization Status"
    }
  },
  "Promo Codes": {
    "query": "SELECT Code__c, Expiration_Date__c FROM Promo_Codes__dlm WHERE AccountId__c = 'XX' OR ContactId__c = 'XX'",
    "fieldLabels": {
      "Code__c": "Promo Code",
      "Expiration_Date__c": "Expires"
    }
  },
  "Systems": {
    "query": "SELECT Controller_Install_Date__c FROM Systems_SNAP__dlm WHERE Account_c__c = 'XX'",
    "fieldLabels": {
      "Controller_Install_Date__c": "Controller Install Date"
    }
  }
}
