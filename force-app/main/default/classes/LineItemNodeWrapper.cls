public class LineItemNodeWrapper {

    public Map<String, Object> tags     { get; set; }
    public List<Object>        dataPath { get; set; }
    public List<Object>        salesPath { get; set; }
    public Boolean             deleted  { get; set; }

    public String productCode       { get; set; }
    public String stockKeepingUnit  { get; set; } // reads context tag: ItemStockKeepingUnit
    public String sellingModelType  { get; set; }
    public String segmentIdentifier { get; set; } // Quote context: ItemSegmentIdentifier tag
    public String segmentName       { get; set; } // Quote context: ItemSegmentName tag (e.g. "Year 1")
    public String itemGroup         { get; set; } // Quote context: SalesTransactionItemGroup tag (line group Id)
    public String rampIdentifier    { get; set; } // Order context: RampIdentifier tag
    public String startDate         { get; set; }
    public String effectiveFrom     { get; set; }
    public String parentContextId   { get; set; }
    public String endDate           { get; set; }
    public Decimal haasHardwareAmount { get; set; } // reads context tag: HaaS_Hardware_Amount__c (ARM-108)

    // Added for QuoteMarginRollupPostHook.applyNetUnitPriceFallback.
    // Tag names below are a best guess matching the field-name convention
    // that worked for HaaS_Hardware_Amount__c/Line_of_Business__c — NOT yet
    // confirmed against the Context Tags tab the way UnitPrice/UnitCost were
    // (UnitPrice's real tag turned out to be "InputUnitPrice", a different
    // string from the field name, so a wrong guess here would compile fine
    // and silently return null forever rather than error). Verify each of
    // these against Setup > Context Definitions > Ascend_SalesTransactionContext
    // > Context Tags (Node Tag: SalesTransactionItem) before trusting the values.
    public String netUnitPrice      { get; set; } // reads context tag: NetUnitPrice (UNVERIFIED)
    // Quantity's context TAG is 'LineItemQuantity', not 'Quantity' — 'Quantity'
    // is the ATTRIBUTE name. Verified in Ascend_SalesTransactionContext:
    // contextAttributes > title 'Quantity' > contextTags > title
    // 'LineItemQuantity' (dataType number, fieldType inputoutput). This read
    // passed 'Quantity' and so returned null on every line — precisely the
    // silent-null failure the note above warns about.
    public String quantity          { get; set; } // reads context tag: LineItemQuantity
    public String totalPrice        { get; set; } // reads context tag: TotalPrice (UNVERIFIED)
    public String netTotalPrice     { get; set; } // reads context tag: NetTotalPrice (UNVERIFIED)
    public Decimal pricingTermCount { get; set; } // reads context tag: PricingTermCount (ARM-108)
    public Decimal discount         { get; set; } // reads context tag: Discount (ARM-108, UNVERIFIED)

    // Confirmed present, unlike the guesses above: 'ListPrice' is a real
    // SalesTransactionItem context attribute on Ascend_SalesTransactionContext,
    // hydrated from QuoteLineItem.ListPrice by the QuoteEntitiesMapping.
    // Unlike the SOQL join in QuoteMarginRollupPostHook's NetUnitPrice
    // fallback, this tag is readable on lines added in THIS transaction —
    // they have no saved QuoteLineItem row to query yet.
    public String listPrice         { get; set; } // reads context tag: ListPrice

    // Written by JTLPreHook's bundle flagging on the pass that adds the bundle,
    // then PERSISTED on the QuoteLineItem — which is what makes it readable on
    // every later reprice. It is the only per-line "this line came in as part
    // of a bundle" signal a PRE-hook can see: ParentContextId, MainItem,
    // RootItem and ParentSalesTransactionItem are all null this early (see the
    // BUNDLE DETECTION note in JTLPreHook), so the structural parent link is
    // not an option here.
    public Boolean isPartOfBundle   { get; set; } // reads context tag: Is_Part_Of_Bundle__c

    public LineItemNodeWrapper(Object node) {

        Map<String, Object> obj = (Map<String, Object>) node;

        this.dataPath = (List<Object>) obj.get('dataPath');

        if (dataPath != null && dataPath.size() >= 3) {
            this.salesPath = new List<Object>{
                dataPath.get(1),
                dataPath.get(2)
            };
        }

        this.tags = (Map<String, Object>) obj.get('tagValue');

        this.deleted = false;
        if (tags != null && tags.containsKey('IsDeleted')) {
            Object del =
                ((Map<String, Object>) tags.get('IsDeleted'))
                .get('tagValue');
            if (del != null) {
                this.deleted = Boolean.valueOf(String.valueOf(del));
            }
        }

        this.productCode       = getString('ProductCode');
        this.stockKeepingUnit  = getString('ItemStockKeepingUnit');
        this.sellingModelType  = getString('SellingModelType');
        this.segmentIdentifier = getString('ItemSegmentIdentifier');
        this.segmentName       = getString('ItemSegmentName');
        this.itemGroup         = getString('SalesTransactionItemGroup');
        this.rampIdentifier    = getString('RampIdentifier');
        this.startDate         = getString('StartDate');
        this.effectiveFrom     = getString('EffectiveFrom');
        this.parentContextId   = getString('ParentContextId');
        this.endDate           = getString('EndDate');
        this.haasHardwareAmount = getDecimal('HaaS_Hardware_Amount__c');
        this.netUnitPrice       = getString('NetUnitPrice');
        this.quantity           = getString('LineItemQuantity');
        this.totalPrice         = getString('TotalPrice');
        this.netTotalPrice      = getString('NetTotalPrice');
        this.pricingTermCount   = getDecimal('PricingTermCount');
        this.discount           = getDecimal('Discount');
        this.listPrice          = getString('ListPrice');
        this.isPartOfBundle     = getBoolean('Is_Part_Of_Bundle__c');
    }

    public Boolean isValid() {
        return dataPath  != null
            && dataPath.size() >= 3
            && salesPath != null
            && salesPath.size() == 2;
    }

    private String getString(String key) {
        try {
            if (tags != null && tags.containsKey(key)) {
                Object val =
                    ((Map<String, Object>) tags.get(key))
                    .get('tagValue');
                return val != null ? String.valueOf(val) : null;
            }
        } catch (Exception e) {}
        return null;
    }

    // Returns false, not null, when the tag is absent — every caller treats a
    // missing flag as "not set", and a null would force null-guards at each one.
    private Boolean getBoolean(String key) {
        try {
            if (tags != null && tags.containsKey(key)) {
                Object val =
                    ((Map<String, Object>) tags.get(key))
                    .get('tagValue');
                return val != null && Boolean.valueOf(String.valueOf(val));
            }
        } catch (Exception e) {}
        return false;
    }

    private Decimal getDecimal(String key) {
        try {
            if (tags != null && tags.containsKey(key)) {
                Object val =
                    ((Map<String, Object>) tags.get(key))
                    .get('tagValue');
                return val != null ? Decimal.valueOf(String.valueOf(val)) : null;
            }
        } catch (Exception e) {}
        return null;
    }

    public Boolean isTermBased() {
        return sellingModelType != null
            && sellingModelType.toLowerCase().contains('term');
    }

    // True when this node's own id (dataPath[2]) is a real, already-saved
    // Salesforce Id — i.e. the line existed before this transaction,
    // as opposed to being newly added in the current edit.
    public Boolean isPersisted() {
        if (dataPath == null || dataPath.size() < 3) return false;
        try {
            Id testId = Id.valueOf(String.valueOf(dataPath.get(2)));
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}