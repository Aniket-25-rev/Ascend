// Deployment plan for Revenue Cloud Advanced (RCA) configuration.
//
// RCA config is *data*, not metadata: catalogs, categories, products, attributes,
// selling models, bundles and price data all live in standard SObjects. So a
// "deploy" is an ordered, dependency-aware upsert — not a Metadata API zip.
//
// Ordering matters: a node may only reference nodes defined above it.
// `key` is the External ID field used to match records across orgs. Every object
// below needs that field created once per org (see README: bootstrapExternalIds).

export const RCA_PLAN = [
    {
        object: 'ProductClassification',
        key: 'Ascend_Key__c',
        fields: ['Name', 'Code', 'Status', 'Description'],
        refs: {}
    },
    {
        object: 'AttributeDefinition',
        key: 'Ascend_Key__c',
        fields: ['Name', 'Code', 'Label', 'DataType', 'DeveloperName', 'IsActive', 'PicklistId'],
        refs: { PicklistId: 'AttributePicklist' }
    },
    {
        object: 'AttributeCategory',
        key: 'Ascend_Key__c',
        fields: ['Name', 'Code', 'Description'],
        refs: {}
    },
    {
        object: 'AttributeCategoryAttribute',
        key: 'Ascend_Key__c',
        fields: ['AttributeCategoryId', 'AttributeDefinitionId', 'Sequence'],
        refs: { AttributeCategoryId: 'AttributeCategory', AttributeDefinitionId: 'AttributeDefinition' }
    },
    {
        object: 'ProductClassificationAttr',
        key: 'Ascend_Key__c',
        fields: [
            'ProductClassificationId',
            'AttributeDefinitionId',
            'AttributeCategoryId',
            'Sequence',
            'IsRequired',
            'IsHidden',
            'IsReadOnly',
            'DefaultValue'
        ],
        refs: {
            ProductClassificationId: 'ProductClassification',
            AttributeDefinitionId: 'AttributeDefinition',
            AttributeCategoryId: 'AttributeCategory'
        }
    },
    {
        object: 'ProductCatalog',
        key: 'Ascend_Key__c',
        fields: ['Name', 'Code', 'Description', 'EffectiveStartDate', 'EffectiveEndDate'],
        refs: {}
    },
    {
        object: 'ProductCategory',
        key: 'Ascend_Key__c',
        fields: ['Name', 'Code', 'CatalogId', 'ParentCategoryId', 'SortOrder', 'Description'],
        refs: { CatalogId: 'ProductCatalog', ParentCategoryId: 'ProductCategory' },
        selfReferencing: true
    },
    {
        object: 'Product2',
        key: 'Ascend_Key__c',
        fields: [
            'Name',
            'ProductCode',
            'Description',
            'IsActive',
            'Family',
            'Type',
            'ConfigureDuringSale',
            'BasedOnId',
            'ProductClassId'
        ],
        refs: { ProductClassId: 'ProductClassification', BasedOnId: 'Product2' },
        selfReferencing: true
    },
    {
        object: 'ProductCategoryProduct',
        key: 'Ascend_Key__c',
        fields: ['ProductCategoryId', 'ProductId'],
        refs: { ProductCategoryId: 'ProductCategory', ProductId: 'Product2' }
    },
    {
        object: 'ProductSellingModel',
        key: 'Ascend_Key__c',
        fields: ['Name', 'SellingModelType', 'PricingTermUnit', 'PricingTerm', 'Status'],
        refs: {}
    },
    {
        object: 'ProductSellingModelOption',
        key: 'Ascend_Key__c',
        fields: ['Product2Id', 'ProductSellingModelId'],
        refs: { Product2Id: 'Product2', ProductSellingModelId: 'ProductSellingModel' }
    },
    {
        object: 'ProductComponentGroup',
        key: 'Ascend_Key__c',
        fields: [
            'Name',
            'Code',
            'ParentGroupId',
            'ParentProductId',
            'Sequence',
            'MinBundleComponents',
            'MaxBundleComponents',
            'Description'
        ],
        refs: { ParentGroupId: 'ProductComponentGroup', ParentProductId: 'Product2' },
        selfReferencing: true
    },
    {
        object: 'ProductRelatedComponent',
        key: 'Ascend_Key__c',
        fields: [
            'ParentProductId',
            'ChildProductId',
            'ChildProductClassificationId',
            'ProductComponentGroupId',
            'ProductRelationshipTypeId',
            'Quantity',
            'MinQuantity',
            'MaxQuantity',
            'IsQuantityEditable',
            'IsComponentRequired',
            'DoesBundlePriceIncludeChild',
            'Sequence'
        ],
        refs: {
            ParentProductId: 'Product2',
            ChildProductId: 'Product2',
            ChildProductClassificationId: 'ProductClassification',
            ProductComponentGroupId: 'ProductComponentGroup'
        }
    },
    {
        object: 'Pricebook2',
        key: 'Ascend_Key__c',
        fields: ['Name', 'Description', 'IsActive'],
        refs: {}
    },
    {
        object: 'PricebookEntry',
        key: 'Ascend_Key__c',
        fields: ['Pricebook2Id', 'Product2Id', 'UnitPrice', 'IsActive', 'ProductSellingModelId'],
        refs: {
            Pricebook2Id: 'Pricebook2',
            Product2Id: 'Product2',
            ProductSellingModelId: 'ProductSellingModel'
        }
    },
    {
        object: 'PriceAdjustmentSchedule',
        key: 'Ascend_Key__c',
        fields: ['Name', 'AdjustmentMethod', 'IsActive', 'Pricebook2Id', 'ScheduleType'],
        refs: { Pricebook2Id: 'Pricebook2' }
    },
    {
        object: 'PriceAdjustmentTier',
        key: 'Ascend_Key__c',
        fields: [
            'PriceAdjustmentScheduleId',
            'ProductId',
            'LowerBound',
            'UpperBound',
            'Adjustment',
            'TierType'
        ],
        refs: { PriceAdjustmentScheduleId: 'PriceAdjustmentSchedule', ProductId: 'Product2' }
    }
];

export const planFor = (objects) =>
    objects && objects.length ? RCA_PLAN.filter((n) => objects.includes(n.object)) : RCA_PLAN;
