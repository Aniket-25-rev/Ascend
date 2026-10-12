import { LightningElement, api, wire } from 'lwc';
import getOrderProducts from '@salesforce/apex/OrderProductTableController.getOrderProducts';

function formatPlain(value) {
    return value === null || value === undefined || value === '' ? '-' : String(value);
}

function formatBoolean(value) {
    return value === null || value === undefined ? '-' : value ? 'True' : 'False';
}

function formatDate(value) {
    if (!value) {
        return '-';
    }
    const [year, month, day] = value.split('-');
    return `${parseInt(month, 10)}/${parseInt(day, 10)}/${year}`;
}

function monthsBetween(startDateValue, endDateValue) {
    if (!startDateValue || !endDateValue) {
        return 0;
    }

    const startDate = new Date(`${startDateValue}T00:00:00`);
    const endDate = new Date(`${endDateValue}T00:00:00`);
    if (Number.isNaN(startDate.getTime()) || Number.isNaN(endDate.getTime()) || endDate < startDate) {
        return 0;
    }

    const monthDifference = (endDate.getFullYear() - startDate.getFullYear()) * 12
        + endDate.getMonth() - startDate.getMonth();
    return monthDifference + (endDate.getDate() >= startDate.getDate() ? 1 : 0);
}

function formatDateTime(value) {
    if (!value) {
        return '-';
    }
    const date = new Date(value);
    const datePart = `${date.getMonth() + 1}/${date.getDate()}/${date.getFullYear()}`;
    const timePart = date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    return `${datePart}, ${timePart}`;
}

function formatCurrency(value) {
    if (value === null || value === undefined) {
        return '-';
    }
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD'
    }).format(value);
}

function formatPercent(value) {
    if (value === null || value === undefined) {
        return '-';
    }
    return `${value}%`;
}

function formatPercentFixed(value) {
    if (value === null || value === undefined) {
        return '-';
    }
    return `${Number(value).toFixed(2)}%`;
}

function formatNegativeCurrency(value) {
    if (!value) {
        return '-';
    }
    return `-${formatCurrency(value)}`;
}

const MIN_COLUMN_WIDTH = 60;

function makeColumn(key, label, width) {
    return { key, label, width, styleWidth: `width:${width}px` };
}

function defaultColumns() {
    return [
        makeColumn('service', 'Service', 200),
        makeColumn('startDate', 'Start Date', 110),
        makeColumn('endDate', 'End Date', 110),
        makeColumn('quantity', 'Quantity', 90),
        makeColumn('discountAmount', 'Discount Amount', 130),
        makeColumn('discountPercent', 'Discount (%)', 110),
        makeColumn('listPrice', 'List Price', 110),
        makeColumn('mrr', 'Quote Line Item ID (MRR)', 200),
        makeColumn('netUnitPrice', 'Net Unit Price', 130),
        makeColumn('netTotalPrice', 'Net Total Price', 130),
        makeColumn('rampAction', '', 70),
        makeColumn('pricingTermCount', 'Pricing Term Count', 150)
    ];
}

const SORTABLE_FIELDS = {
    service: { field: 'productName', type: 'string' },
    startDate: { field: 'serviceDate', type: 'date' },
    endDate: { field: 'endDate', type: 'date' },
    quantity: { field: 'quantity', type: 'number' },
    discountAmount: { field: 'discountAmount', type: 'number' },
    discountPercent: { field: 'discountPercent', type: 'number' },
    listPrice: { field: 'listPrice', type: 'number' },
    mrr: { field: 'mrr', type: 'number' },
    netUnitPrice: { field: 'netUnitPrice', type: 'number' },
    netTotalPrice: { field: 'netTotalPrice', type: 'number' },
    pricingTermCount: { field: 'pricingTermCount', type: 'number' }
};

const FULL_ACCESS_RECORD_TYPES = ['Managed Services', 'Churn'];
const PROFESSIONAL_SERVICES_RECORD_TYPE = 'Professional Services';
const PROFESSIONAL_SERVICES_COLUMN_KEYS = ['service', 'quantity', 'listPrice', 'netUnitPrice', 'netTotalPrice'];

function compareValues(a, b, type) {
    const aEmpty = a === null || a === undefined || a === '';
    const bEmpty = b === null || b === undefined || b === '';
    if (aEmpty && bEmpty) {
        return 0;
    }
    if (aEmpty) {
        return 1;
    }
    if (bEmpty) {
        return -1;
    }
    if (type === 'string') {
        return String(a).localeCompare(String(b));
    }
    if (type === 'date') {
        return a < b ? -1 : a > b ? 1 : 0;
    }
    return Number(a) - Number(b);
}

function sortItems(items, sortColumnKey, sortDirection) {
    const config = SORTABLE_FIELDS[sortColumnKey];
    if (!config) {
        return items;
    }
    const sorted = [...items].sort((a, b) => compareValues(a[config.field], b[config.field], config.type));
    return sortDirection === 'desc' ? sorted.reverse() : sorted;
}

function defaultFilters() {
    const filters = {};
    Object.keys(SORTABLE_FIELDS).forEach((key) => {
        filters[key] = SORTABLE_FIELDS[key].type === 'date' ? { from: '', to: '' } : '';
    });
    return filters;
}

function matchesFilters(item, filters) {
    return Object.keys(SORTABLE_FIELDS).every((key) => {
        const config = SORTABLE_FIELDS[key];
        const itemValue = item[config.field];

        if (config.type === 'date') {
            const { from, to } = filters[key];
            if (!from && !to) {
                return true;
            }
            if (!itemValue) {
                return false;
            }
            if (from && itemValue < from) {
                return false;
            }
            if (to && itemValue > to) {
                return false;
            }
            return true;
        }

        const filterValue = filters[key];
        if (!filterValue) {
            return true;
        }
        if (itemValue === null || itemValue === undefined) {
            return false;
        }
        return String(itemValue).toLowerCase().includes(String(filterValue).toLowerCase());
    });
}

function filterItems(items, filters) {
    return items.filter((item) => matchesFilters(item, filters));
}

export default class OrderProductTable extends LightningElement {
    @api recordId;

    groups = [];
    ungroupedItems = [];
    hasGroups = false;
    itemCount = 0;
    error;
    isLoading = true;

    itemsByKey = new Map();
    groupsByKey = new Map();

    showDetailPanel = false;
    showRampModal = false;
    detailMode = 'item';
    selectedItem;
    selectedGroup;
    selectedRamp;
    activeDetailTab = 'details';

    hoveredCalcRow;

    columns = defaultColumns();
    resizingColumnKey;
    dragStartX = 0;
    dragStartWidth = 0;

    sortColumnKey;
    sortDirection = 'asc';

    showFilterRow = false;
    filters = defaultFilters();

    recordTypeName;

    async connectedCallback() {
        let data = await getOrderProducts({ orderId: this.recordId })
        if (data) {
            this.itemsByKey = new Map();
            this.groupsByKey = new Map();
            this.hasGroups = data.some((item) => item.OrderItemGroup);
            this.recordTypeName = data.length > 0 ? data[0]?.Order?.Opportunity?.RecordType?.Name : undefined;
            const mappedItems = data.map((item) => this.mapItem(item));

            if (this.hasGroups) {
                this.itemCount = data.length;
                this.groups = this.buildGroups(data);
                this.ungroupedItems = [];
            } else {
                const primaryItems = data.filter((item) => (!(item.RampIdentifier) || item.IsPrimarySegment === true));
                this.itemCount = primaryItems.length;
                this.groups = [];
                this.ungroupedItems = mappedItems.filter((item) => !item.rampIdentifier || item.isPrimarySegment);
            }

            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.groups = [];
            this.ungroupedItems = [];
            this.itemsByKey = new Map();
            this.groupsByKey = new Map();
            this.hasGroups = false;
            this.itemCount = 0;
            this.recordTypeName = undefined;
        }
        this.isLoading = false;
    }

    mapItem(item) {
        const mapped = {
            key: 'i-' + item.Id,
            id: item.Id,
            productName: item.Product2 ? item.Product2.Name : '',
            serviceCode: item.Product2 ? item.Product2.ProductCode : undefined,
            serviceDescription: item.Product2 ? item.Product2.Description : undefined,
            lineDescription: item.Description,
            lineNumber: item.LineNumber,
            serviceDate: item.ServiceDate,
            endDate: item.EndDate,
            quantity: item.Quantity,
            quantityUnitOfMeasure: item.QuantityUnitOfMeasure ? item.QuantityUnitOfMeasure.Name : undefined,
            discountAmount: item.DiscountAmount,
            discountPercent: item.Discount,
            listPrice: item.ListPrice,
            unitPrice: item.UnitPrice,
            productSubtotal: item.TotalLineAmount,
            totalPrice: item.TotalPrice,
            partnerDiscountPercent: item.PartnerDiscountPercent,
            mrr: item.QuoteLineItem ? item.QuoteLineItem.MRR__c : undefined,
            netUnitPrice: item.NetUnitPrice,
            netTotalPrice: item.NetTotalPrice,
            subscriptionTerm: item.SubscriptionTerm,
            pricingTermCount: item.PricingTermCount,
            startQuantity: item.StartQuantity,
            endQuantity: item.EndQuantity,
            rampIdentifier: item.RampIdentifier,
            isPrimarySegment: item.IsPrimarySegment === true,
            showRampIndicator: !this.hasGroups
                && item.IsPrimarySegment === true
                && item.RampIdentifier !== undefined
                && item.RampIdentifier !== null,
            quantityClass: !this.hasGroups
                && item.IsPrimarySegment === true
                && item.RampIdentifier !== undefined
                && item.RampIdentifier !== null
                ? 'ramp-quantity'
                : ''
        };

        this.itemsByKey.set(mapped.key, mapped);
        return mapped;
    }

    buildGroups(orderItems) {
        const groupOrder = [];
        const groupsById = new Map();

        orderItems.forEach((item) => {
            const group = item.OrderItemGroup;
            const groupId = group ? group.Id : 'ungrouped';

            if (!groupsById.has(groupId)) {
                const groupRecord = {
                    key: 'g-' + groupId,
                    id: group ? group.Id : undefined,
                    name: group ? group.Name : '—',
                    orderId: group ? group.OrderId : undefined,
                    startDate: group ? group.StartDate : undefined,
                    endDate: group ? group.EndDate : undefined,
                    sortOrder: group ? group.SortOrder : undefined,
                    type: group ? group.Type : undefined,
                    description: group ? group.Description : undefined,
                    summarySubtotal: group ? group.SummarySubtotal : undefined,
                    isRamped: group ? group.IsRamped : undefined,
                    segmentType: group ? group.SegmentType : undefined,
                    createdById: group ? group.CreatedById : undefined,
                    lastModifiedById: group ? group.LastModifiedById : undefined,
                    createdDate: group ? group.CreatedDate : undefined,
                    lastModifiedDate: group ? group.LastModifiedDate : undefined,
                    expanded: true,
                    items: []
                };
                groupsById.set(groupId, groupRecord);
                this.groupsByKey.set(groupRecord.key, groupRecord);
                groupOrder.push(groupId);
            }

            groupsById.get(groupId).items.push(this.mapItem(item));
        });

        return groupOrder.map((groupId) => groupsById.get(groupId));
    }

    get groupCount() {
        return this.groups.length;
    }

    get scrollWrapperClass() {
        return this.resizingColumnKey ? 'table-scroll-wrapper is-resizing-columns' : 'table-scroll-wrapper';
    }

    get showComponent() {
        return FULL_ACCESS_RECORD_TYPES.includes(this.recordTypeName)
            || this.recordTypeName === PROFESSIONAL_SERVICES_RECORD_TYPE;
    }

    get visibleColumnKeys() {
        const keys = this.recordTypeName === PROFESSIONAL_SERVICES_RECORD_TYPE
            ? [...PROFESSIONAL_SERVICES_COLUMN_KEYS]
            : this.columns
                .filter((column) => column.key !== 'rampAction')
                .map((column) => column.key);
        if (this.showRampActionColumn) {
            keys.push('rampAction');
        }
        return new Set(keys);
    }

    get showRampActionColumn() {
        return !this.hasGroups && this.recordTypeName === PROFESSIONAL_SERVICES_RECORD_TYPE;
    }

    get visibleColumns() {
        const keys = this.visibleColumnKeys;
        return this.columns.filter((column) => keys.has(column.key));
    }

    get columnCount() {
        return this.visibleColumns.length;
    }

    get showDateColumns() {
        return this.visibleColumnKeys.has('startDate');
    }

    get showDiscountAmountColumn() {
        return this.visibleColumnKeys.has('discountAmount');
    }

    get showDiscountPercentColumn() {
        return this.visibleColumnKeys.has('discountPercent');
    }

    get showMrrColumn() {
        return this.visibleColumnKeys.has('mrr');
    }

    get showPricingTermCountColumn() {
        return this.visibleColumnKeys.has('pricingTermCount');
    }

    get groupRowColspan() {
        const dateColumnsVisible = this.showDateColumns ? 2 : 0;
        return this.visibleColumns.length - 1 - dateColumnsVisible;
    }

    get displayColumns() {
        return this.visibleColumns.map((column) => {
            const isSorted = column.key === this.sortColumnKey;
            const config = SORTABLE_FIELDS[column.key];
            const isDateFilter = config?.type === 'date';
            const filterState = this.filters[column.key];

            return {
                ...column,
                isSorted,
                isActionColumn: column.key === 'rampAction',
                sortIcon: this.sortDirection === 'asc' ? 'utility:arrowup' : 'utility:arrowdown',
                ariaSort: isSorted ? (this.sortDirection === 'asc' ? 'ascending' : 'descending') : 'none',
                isDateFilter,
                filterValue: isDateFilter ? undefined : filterState || '',
                filterFrom: isDateFilter ? filterState.from : undefined,
                filterTo: isDateFilter ? filterState.to : undefined
            };
        });
    }

    handleToggleFilterRow() {
        this.showFilterRow = !this.showFilterRow;
    }

    handleTextFilterChange(event) {
        const columnKey = event.target.dataset.columnKey;
        this.filters = { ...this.filters, [columnKey]: event.target.value };
    }

    handleDateFilterChange(event) {
        const columnKey = event.target.dataset.columnKey;
        const bound = event.target.dataset.bound;
        this.filters = {
            ...this.filters,
            [columnKey]: { ...this.filters[columnKey], [bound]: event.target.value }
        };
    }

    handleClearFilters() {
        this.filters = defaultFilters();
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    handleSortColumn(event) {
        const columnKey = event.currentTarget.dataset.columnKey;
        if (!SORTABLE_FIELDS[columnKey]) {
            return;
        }

        if (this.sortColumnKey === columnKey) {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortColumnKey = columnKey;
            this.sortDirection = 'asc';
        }
    }

    handleSortColumnKeyUp(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            this.handleSortColumn(event);
        }
    }

    get rows() {
        if (!this.hasGroups) {
            const filteredItems = filterItems(this.ungroupedItems, this.filters);
            const sortedItems = sortItems(filteredItems, this.sortColumnKey, this.sortDirection);
            return sortedItems.map((item) => ({
                ...item,
                isGroup: false,
                rowClass: 'slds-hint-parent item-row'
            }));
        }

        const flatRows = [];

        this.groups.forEach((group) => {
            const filteredItems = filterItems(group.items, this.filters);
            if (filteredItems.length === 0) {
                return;
            }

            flatRows.push({
                key: group.key,
                isGroup: true,
                rowClass: 'slds-hint-parent group-row',
                name: group.name,
                startDate: group.startDate,
                endDate: group.endDate,
                expanded: group.expanded,
                chevronIcon: group.expanded ? 'utility:chevrondown' : 'utility:chevronright'
            });

            if (group.expanded) {
                const sortedItems = sortItems(filteredItems, this.sortColumnKey, this.sortDirection);
                sortedItems.forEach((item) => {
                    flatRows.push({
                        ...item,
                        isGroup: false,
                        rowClass: 'slds-hint-parent item-row'
                    });
                });
            }
        });

        return flatRows;
    }

    handleToggleGroup(event) {
        const groupKey = event.currentTarget.dataset.groupKey;
        this.groups = this.groups.map((group) =>
            group.key === groupKey ? { ...group, expanded: !group.expanded } : group
        );
    }

    handleToggleGroupKeyUp(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            this.handleToggleGroup(event);
        }
    }

    handleShowCalcDetails(event) {
        this.clearCalcHideTimeout();

        const itemKey = event.currentTarget.dataset.itemKey;
        const item = this.itemsByKey.get(itemKey);
        if (!item) {
            return;
        }

        const rect = event.currentTarget.getBoundingClientRect();
        const tailOffset = Math.min(Math.max(rect.width / 2, 16), 256);

        const listPrice = item.listPrice;
        const netUnitPrice = item.netUnitPrice;
        const showTermDiscount = listPrice !== null && listPrice !== undefined
            && netUnitPrice !== null && netUnitPrice !== undefined
            && netUnitPrice < listPrice;

        let discountPercentDisplay;
        let discountAmountDisplay;
        if (showTermDiscount) {
            const termDiscountAmount = listPrice - netUnitPrice;
            const termDiscountPercent = listPrice ? (termDiscountAmount / listPrice) * 100 : 0;
            discountAmountDisplay = formatNegativeCurrency(termDiscountAmount);
            discountPercentDisplay = formatPercentFixed(termDiscountPercent);
        }

        this.hoveredCalcRow = {
            key: itemKey,
            isRampNotice: false,
            style: `left:${rect.left}px; top:${rect.top - 10}px;`,
            tailStyle: `left:${tailOffset}px;`,
            listPriceDisplay: formatCurrency(listPrice),
            showTermDiscount,
            discountPercentDisplay,
            discountAmountDisplay,
            netUnitPriceDisplay: formatCurrency(netUnitPrice)
        };
    }

    handleShowRampDetails(event) {
        this.clearCalcHideTimeout();

        const rect = event.currentTarget.getBoundingClientRect();
        const tailOffset = Math.min(Math.max(rect.width / 2, 16), 256);
        this.hoveredCalcRow = {
            key: event.currentTarget.dataset.itemKey,
            isRampNotice: true,
            style: `left:${rect.left}px; top:${rect.top - 10}px;`,
            tailStyle: `left:${tailOffset}px;`,
            rampMessage: "This line is ramped. You're only seeing the first segment. To view the other segments, select the Ramp row action."
        };
    }

    handleOpenRampModal(event) {
        event.stopPropagation();
        const item = this.itemsByKey.get(event.currentTarget.dataset.itemKey);
        if (!item || !item.showRampIndicator) {
            return;
        }

        const rampItems = [...this.itemsByKey.values()]
            .filter((candidate) => candidate.rampIdentifier === item.rampIdentifier)
            .sort((first, second) => (first.serviceDate || '').localeCompare(second.serviceDate || ''));
        this.selectedRamp = {
            lineItem: {
                productName: item.productName,
                listPrice: formatCurrency(item.listPrice),
                serviceDate: formatDate(item.serviceDate),
                endDate: formatDate(item.endDate),
                netTotalPrice: formatCurrency(item.netTotalPrice)
            },
            subscriptionTerm: rampItems.reduce(
                (totalMonths, segment) => totalMonths + monthsBetween(segment.serviceDate, segment.endDate),
                0
            ),
            segmentType: 'Annual',
            segments: rampItems.map((segment, index) => ({
                key: segment.key,
                number: index + 1,
                name: `Year-${index + 1}`,
                startDate: formatDate(segment.serviceDate),
                endDate: formatDate(segment.endDate),
                listPrice: formatCurrency(segment.listPrice),
                quantity: formatPlain(segment.quantity),
                discountPercent: formatPercent(segment.discountPercent),
                netUnitPrice: formatCurrency(segment.netUnitPrice),
                totalPrice: formatCurrency(segment.netTotalPrice)
            }))
        };
        this.showRampModal = true;
    }

    handleCloseRampModal() {
        this.showRampModal = false;
        this.selectedRamp = undefined;
    }

    stopModalPropagation(event) {
        event.stopPropagation();
    }

    handleHideCalcDetails() {
        this.scheduleCalcHide();
    }

    handleCloseCalcDetails(event) {
        if (event) {
            event.stopPropagation();
        }
        this.clearCalcHideTimeout();
        this.hoveredCalcRow = undefined;
    }

    handleCalcPopoverMouseEnter() {
        this.clearCalcHideTimeout();
    }

    handleCalcPopoverMouseLeave() {
        this.scheduleCalcHide();
    }

    scheduleCalcHide() {
        this.clearCalcHideTimeout();
        this.calcHideTimeoutId = setTimeout(() => {
            this.hoveredCalcRow = undefined;
            this.calcHideTimeoutId = undefined;
        }, 150);
    }

    clearCalcHideTimeout() {
        if (this.calcHideTimeoutId) {
            clearTimeout(this.calcHideTimeoutId);
            this.calcHideTimeoutId = undefined;
        }
    }

    disconnectedCallback() {
        this.clearCalcHideTimeout();
        this.stopColumnResize();
    }

    handleColumnResizeMouseDown(event) {
        event.preventDefault();
        const columnKey = event.currentTarget.dataset.columnKey;
        const column = this.columns.find((col) => col.key === columnKey);
        if (!column) {
            return;
        }

        this.resizingColumnKey = columnKey;
        this.dragStartX = event.clientX;
        this.dragStartWidth = column.width;

        this.boundHandleColumnResizeMouseMove = this.handleColumnResizeMouseMove.bind(this);
        this.boundStopColumnResize = this.stopColumnResize.bind(this);
        window.addEventListener('mousemove', this.boundHandleColumnResizeMouseMove);
        window.addEventListener('mouseup', this.boundStopColumnResize);
    }

    handleColumnResizeMouseMove(event) {
        if (!this.resizingColumnKey) {
            return;
        }

        const delta = event.clientX - this.dragStartX;
        const newWidth = Math.max(MIN_COLUMN_WIDTH, this.dragStartWidth + delta);

        this.columns = this.columns.map((col) =>
            col.key === this.resizingColumnKey ? makeColumn(col.key, col.label, newWidth) : col
        );
    }

    stopColumnResize() {
        this.resizingColumnKey = undefined;
        if (this.boundHandleColumnResizeMouseMove) {
            window.removeEventListener('mousemove', this.boundHandleColumnResizeMouseMove);
            this.boundHandleColumnResizeMouseMove = undefined;
        }
        if (this.boundStopColumnResize) {
            window.removeEventListener('mouseup', this.boundStopColumnResize);
            this.boundStopColumnResize = undefined;
        }
    }

    handleOpenDetail(event) {
        const itemKey = event.currentTarget.dataset.itemKey;
        const item = this.itemsByKey.get(itemKey);
        if (!item) {
            return;
        }

        this.selectedItem = {
            title: item.productName,
            serviceDescription: formatPlain(item.serviceDescription),
            productDetailsExpanded: true,
            pricingDetailsExpanded: true,
            productDetails: [
                { key: 'orderProductId', label: 'Order Product ID', value: formatPlain(item.id) },
                { key: 'lineDescription', label: 'Line Description', value: formatPlain(item.lineDescription) },
                { key: 'lineNumber', label: 'Line Number', value: formatPlain(item.lineNumber) },
                { key: 'serviceCode', label: 'Service Code', value: formatPlain(item.serviceCode) },
                { key: 'serviceName', label: 'Service Name', value: formatPlain(item.productName) }
            ],
            pricingDetails: [
                { key: 'quantity', label: 'Quantity', value: formatPlain(item.quantity) },
                { key: 'quantityUom', label: 'Quantity Unit Of Measure', value: formatPlain(item.quantityUnitOfMeasure) },
                { key: 'productSubtotal', label: 'Product Subtotal', value: formatCurrency(item.productSubtotal) },
                { key: 'totalPrice', label: 'Total Price', value: formatCurrency(item.totalPrice) },
                { key: 'listPrice', label: 'List Price', value: formatCurrency(item.listPrice) },
                { key: 'unitPrice', label: 'Unit Price', value: formatCurrency(item.unitPrice) },
                { key: 'discountPercentage', label: 'Discount (Percentage)', value: formatPercent(item.discountPercent) },
                { key: 'discountAmount', label: 'Discount (Amount)', value: formatCurrency(item.discountAmount) },
                { key: 'partnerDiscountPercent', label: 'Partner Discount Percent', value: formatPercent(item.partnerDiscountPercent) },
                { key: 'netUnitPrice', label: 'Net Unit Price', value: formatCurrency(item.netUnitPrice) },
                { key: 'netTotalPrice', label: 'Net Total Price', value: formatCurrency(item.netTotalPrice) },
                { key: 'subscriptionTerm', label: 'Subscription Term', value: formatPlain(item.subscriptionTerm) },
                { key: 'pricingTermCount', label: 'Pricing Term Count', value: formatPlain(item.pricingTermCount) },
                { key: 'startDate', label: 'Start Date', value: formatDate(item.serviceDate) },
                { key: 'endDate', label: 'End Date', value: formatDate(item.endDate) },
                { key: 'startQuantity', label: 'Start Quantity', value: formatPlain(item.startQuantity) },
                { key: 'endQuantity', label: 'End Quantity', value: formatPlain(item.endQuantity) }
            ]
        };
        this.detailMode = 'item';
        this.activeDetailTab = 'details';
        this.showDetailPanel = true;
    }

    handleToggleProductDetails() {
        this.selectedItem = {
            ...this.selectedItem,
            productDetailsExpanded: !this.selectedItem.productDetailsExpanded
        };
    }

    handleTogglePricingDetails() {
        this.selectedItem = {
            ...this.selectedItem,
            pricingDetailsExpanded: !this.selectedItem.pricingDetailsExpanded
        };
    }

    get productDetailsChevron() {
        return this.selectedItem?.productDetailsExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get pricingDetailsChevron() {
        return this.selectedItem?.pricingDetailsExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    handleOpenGroupDetail(event) {
        event.stopPropagation();
        const groupKey = event.currentTarget.dataset.groupKey;
        const group = this.groupsByKey.get(groupKey);
        if (!group) {
            return;
        }

        this.selectedGroup = {
            title: group.name,
            sections: [
                {
                    key: 'orderProductGroupInfo',
                    title: 'Order Product Group Information',
                    expanded: true,
                    chevronIcon: 'utility:chevrondown',
                    fields: [
                        { key: 'name', label: 'Order Product Group Name', value: formatPlain(group.name) },
                        { key: 'orderId', label: 'Order ID', value: formatPlain(group.orderId) },
                        { key: 'startDate', label: 'Start Date', value: formatDate(group.startDate) },
                        { key: 'endDate', label: 'End Date', value: formatDate(group.endDate) },
                        { key: 'sortOrder', label: 'Sort Order', value: formatPlain(group.sortOrder) },
                        { key: 'type', label: 'Order Product Group Type', value: formatPlain(group.type) },
                        { key: 'summarySubtotal', label: 'Summary Subtotal', value: formatCurrency(group.summarySubtotal) },
                        { key: 'description', label: 'Description', value: formatPlain(group.description) }
                    ]
                },
                {
                    key: 'groupRampSegmentInfo',
                    title: 'Group Ramp Segment Information',
                    expanded: true,
                    chevronIcon: 'utility:chevrondown',
                    fields: [
                        { key: 'isRamped', label: 'Is Ramped', value: formatBoolean(group.isRamped) },
                        { key: 'segmentType', label: 'Segment Type', value: formatPlain(group.segmentType) }
                    ]
                },
                {
                    key: 'systemInfo',
                    title: 'System Information',
                    expanded: true,
                    chevronIcon: 'utility:chevrondown',
                    fields: [
                        { key: 'createdById', label: 'Created By ID', value: formatPlain(group.createdById) },
                        { key: 'lastModifiedById', label: 'Last Modified By ID', value: formatPlain(group.lastModifiedById) },
                        { key: 'createdDate', label: 'Created Date', value: formatDateTime(group.createdDate) },
                        { key: 'lastModifiedDate', label: 'Last Modified Date', value: formatDateTime(group.lastModifiedDate) }
                    ]
                }
            ]
        };
        this.detailMode = 'group';
        this.showDetailPanel = true;
    }

    handleToggleGroupSection(event) {
        const sectionKey = event.currentTarget.dataset.sectionKey;
        this.selectedGroup = {
            ...this.selectedGroup,
            sections: this.selectedGroup.sections.map((section) => {
                if (section.key !== sectionKey) {
                    return section;
                }
                const expanded = !section.expanded;
                return {
                    ...section,
                    expanded,
                    chevronIcon: expanded ? 'utility:chevrondown' : 'utility:chevronright'
                };
            })
        };
    }

    handleCloseDetail() {
        this.showDetailPanel = false;
        this.selectedItem = undefined;
        this.selectedGroup = undefined;
    }

    handleSelectDetailsTab() {
        this.activeDetailTab = 'details';
    }

    handleSelectAttributesTab() {
        this.activeDetailTab = 'attributes';
    }

    get detailsTabClass() {
        return this.activeDetailTab === 'details'
            ? 'slds-tabs_default__item slds-is-active'
            : 'slds-tabs_default__item';
    }

    get attributesTabClass() {
        return this.activeDetailTab === 'attributes'
            ? 'slds-tabs_default__item slds-is-active'
            : 'slds-tabs_default__item';
    }

    get isDetailsTabActive() {
        return this.activeDetailTab === 'details';
    }

    get isAttributesTabActive() {
        return this.activeDetailTab === 'attributes';
    }

    get isItemDetailMode() {
        return this.detailMode === 'item';
    }

    get isGroupDetailMode() {
        return this.detailMode === 'group';
    }

    get detailPanelTitle() {
        return this.isGroupDetailMode ? this.selectedGroup?.title : this.selectedItem?.title;
    }
}