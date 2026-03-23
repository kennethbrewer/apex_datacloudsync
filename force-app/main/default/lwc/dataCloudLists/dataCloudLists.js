import { LightningElement, api, wire } from 'lwc';
import getListData from '@salesforce/apex/DataCloudListsController.getListData';

export default class DataCloudLists extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api listName;

    columns;
    rows;
    title;
    error;

    @wire(getListData, {
        recordId: '$recordId',
        objectApiName: '$objectApiName',
        listName: '$listName'
    })
    wiredData({ error, data }) {
        if (data) {
            this.columns = data.columns;
            this.rows = data.rows;
            this.title = data.title;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'Error loading Data Cloud data';
        }
    }
}