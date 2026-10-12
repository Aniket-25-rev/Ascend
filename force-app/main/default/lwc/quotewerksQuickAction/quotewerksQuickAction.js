import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import getQuoteContext from '@salesforce/apex/QuoteWerksQuickActionController.getQuoteContext';

const QUOTEWERKS_BASE_URL =
    'https://www.qwcontent.com/QuoteWerksURLProtocolRedirector.aspx';

export default class QuoteWerksQuickAction extends LightningElement {
    _recordId;
    context;
    errorMessage;
    isLoading = true;
    loadedOpportunityId;

    @api
    set recordId(value) {
        this._recordId = value;

        if (value && value !== this.loadedOpportunityId) {
            this.loadQuoteContext();
        }
    }

    get recordId() {
        return this._recordId;
    }

    get opportunityName() {
        return this.context?.opportunityName || 'this Opportunity';
    }

    get disableContinue() {
        return this.isLoading || !!this.errorMessage || !this.context;
    }

    async loadQuoteContext() {
        this.isLoading = true;
        this.errorMessage = undefined;
        this.loadedOpportunityId = this.recordId;

        try {
            this.context = await getQuoteContext({
                opportunityId: this.recordId
            });
        } catch (error) {
            this.context = undefined;
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleContinue() {
        const quoteWerksUrl = this.buildQuoteWerksUrl();

        const quoteWerksWindow = window.open(quoteWerksUrl, '_blank');

        if (quoteWerksWindow) {
            quoteWerksWindow.opener = null;
        } else {
            this.errorMessage =
                'Your browser blocked the QuoteWerks tab. Allow pop-ups for Salesforce and try again.';
            return;
        }

        this.closeAction();
    }

    handleCancel() {
        this.closeAction();
    }

    buildQuoteWerksUrl() {
        const parameters = new URLSearchParams();

        parameters.set('RedirectorAction', 'newquote');
        parameters.set('source', 'salesforce.com');
        parameters.set('context', 'opportunity');
        parameters.set('SoldToCMOpportunityRecID', this.valueOrEmpty(this.context.opportunityId));
        parameters.set('DocName', this.valueOrEmpty(this.context.opportunityName));
        parameters.set('SoldToCMCompanyRecID', this.valueOrEmpty(this.context.accountId));
        parameters.set('SoldToCompany', this.valueOrEmpty(this.context.accountName));
        parameters.set('SoldToCMContactRecID', this.valueOrEmpty(this.context.contactId));
        parameters.set('SoldToContact', this.valueOrEmpty(this.context.contactName));
        parameters.set('SoldToEmail', this.valueOrEmpty(this.context.contactEmail));
        parameters.set('SoldToAddress', this.valueOrEmpty(this.context.billingStreet));
        parameters.set('SoldToCity', this.valueOrEmpty(this.context.billingCity));
        parameters.set('SoldToState', this.valueOrEmpty(this.context.billingState));
        parameters.set('SoldToPostalCode', this.valueOrEmpty(this.context.billingPostalCode));
        parameters.set('SoldToCountry', this.valueOrEmpty(this.context.billingCountry));
        parameters.set('ShipToCMCompanyRecID', this.valueOrEmpty(this.context.accountId));
        parameters.set('ShipToCompany', this.valueOrEmpty(this.context.accountName));
        parameters.set('ShipToAddress', this.valueOrEmpty(this.context.shippingStreet));
        parameters.set('ShipToCity', this.valueOrEmpty(this.context.shippingCity));
        parameters.set('ShipToState', this.valueOrEmpty(this.context.shippingState));
        parameters.set('ShipToPostalCode', this.valueOrEmpty(this.context.shippingPostalCode));
        parameters.set('ShipToCountry', this.valueOrEmpty(this.context.shippingCountry));
        parameters.set('SoldToPhone', this.valueOrEmpty(this.context.accountPhone));
        parameters.set('SoldToFax', this.valueOrEmpty(this.context.accountFax));

        return `${QUOTEWERKS_BASE_URL}?${parameters.toString()}`;
    }

    valueOrEmpty(value) {
        return value || '';
    }

    closeAction() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((item) => item.message).join(', ');
        }

        return (
            error?.body?.message ||
            error?.message ||
            'An unexpected error occurred while preparing the QuoteWerks link.'
        );
    }
}