// Deployment graph for the Revenue Cloud components the Metadata API leaves behind:
// Context Definitions, Expression Sets (pricing procedures), and Decision Matrices.
//
// These live as *records* on Tooling/standard objects, so they move by natural-key
// match + create/update — not by external Id (you cannot add a custom External Id
// field to a standard Tooling object).
//
// `key`     natural key used to match a record across orgs (ApiName / DeveloperName)
// `api`     'tooling' or 'data'
// `refs`    lookup field -> the object it points at, resolved through the key map
// `parent`  the ref field that scopes a child to its parent (used for delta compare)
//
// Object and field availability varies by release and licence. Run **Probe org**
// before trusting any lane: it reports what your org actually exposes and strips
// the graph down to that. Anything marked `unverified` is a best guess.

export const CONTEXT_LANE = {
    id: 'context',
    label: 'Context Definitions',
    nodes: [
        {
            object: 'ContextDefinition',
            api: 'tooling',
            key: 'DeveloperName',
            fields: ['DeveloperName', 'MasterLabel', 'Description', 'IsActive'],
            refs: {}
        },
        {
            object: 'ContextDefinitionVersion',
            api: 'tooling',
            key: 'DeveloperName',
            fields: ['DeveloperName', 'ContextDefinitionId', 'VersionNumber', 'Status'],
            refs: { ContextDefinitionId: 'ContextDefinition' },
            parent: 'ContextDefinitionId'
        },
        {
            object: 'ContextNode',
            api: 'tooling',
            key: 'DeveloperName',
            fields: [
                'DeveloperName',
                'MasterLabel',
                'ContextDefinitionVersionId',
                'ParentContextNodeId',
                'NodeType',
                'IsCollection',
                'SequenceNumber'
            ],
            refs: {
                ContextDefinitionVersionId: 'ContextDefinitionVersion',
                ParentContextNodeId: 'ContextNode'
            },
            parent: 'ContextDefinitionVersionId',
            selfReferencing: true
        },
        {
            object: 'ContextAttribute',
            api: 'tooling',
            key: 'DeveloperName',
            fields: [
                'DeveloperName',
                'MasterLabel',
                'ContextNodeId',
                'DataType',
                'IsRequired',
                'IsCollection',
                'DefaultValue',
                'SequenceNumber'
            ],
            refs: { ContextNodeId: 'ContextNode' },
            parent: 'ContextNodeId'
        },
        {
            object: 'ContextMapping',
            api: 'tooling',
            key: 'DeveloperName',
            unverified: true,
            fields: ['DeveloperName', 'ContextDefinitionVersionId', 'MappingType', 'SourceEntity'],
            refs: { ContextDefinitionVersionId: 'ContextDefinitionVersion' },
            parent: 'ContextDefinitionVersionId'
        }
    ]
};

export const EXPRESSION_LANE = {
    id: 'expression',
    label: 'Expression Sets / Pricing Procedures',
    nodes: [
        {
            object: 'ExpressionSetDefinition',
            api: 'tooling',
            key: 'ApiName',
            fields: ['ApiName', 'Name', 'Description', 'UsageType', 'InterfaceSourceType'],
            refs: {}
        },
        {
            object: 'ExpressionSetDefinitionVersion',
            api: 'tooling',
            key: 'ApiName',
            fields: [
                'ApiName',
                'ExpressionSetDefinitionId',
                'VersionNumber',
                'Status',
                'Description',
                'StartDateTime',
                'EndDateTime'
            ],
            refs: { ExpressionSetDefinitionId: 'ExpressionSetDefinition' },
            parent: 'ExpressionSetDefinitionId'
        },
        {
            object: 'ExpressionSet',
            api: 'data',
            key: 'ApiName',
            fields: ['ApiName', 'Name', 'Description', 'UsageType', 'ContextDefinitionId'],
            refs: { ContextDefinitionId: 'ContextDefinition' }
        },
        {
            object: 'ExpressionSetVersion',
            api: 'data',
            key: 'ApiName',
            fields: [
                'ApiName',
                'ExpressionSetId',
                'VersionNumber',
                'Status',
                'ContextDefinitionVersionId',
                'EffectiveFrom',
                'EffectiveTo'
            ],
            refs: {
                ExpressionSetId: 'ExpressionSet',
                ContextDefinitionVersionId: 'ContextDefinitionVersion'
            },
            parent: 'ExpressionSetId'
        },
        {
            object: 'ExpressionSetStep',
            api: 'data',
            key: 'Name',
            fields: [
                'Name',
                'ExpressionSetVersionId',
                'StepType',
                'SequenceNumber',
                'ReferenceObjectId',
                'Description'
            ],
            refs: { ExpressionSetVersionId: 'ExpressionSetVersion' },
            parent: 'ExpressionSetVersionId'
        },
        {
            object: 'ExpressionSetStepRelationship',
            api: 'data',
            key: 'Name',
            unverified: true,
            fields: ['Name', 'ExpressionSetStepId', 'RelatedStepId', 'RelationshipType'],
            refs: {
                ExpressionSetStepId: 'ExpressionSetStep',
                RelatedStepId: 'ExpressionSetStep'
            },
            parent: 'ExpressionSetStepId'
        },
        {
            object: 'ExpressionSetVersionContextDefinition',
            api: 'data',
            key: 'Name',
            unverified: true,
            fields: ['Name', 'ExpressionSetVersionId', 'ContextDefinitionId'],
            refs: {
                ExpressionSetVersionId: 'ExpressionSetVersion',
                ContextDefinitionId: 'ContextDefinition'
            },
            parent: 'ExpressionSetVersionId'
        }
    ]
};

// Decision matrices: metadata deploys via the CLI, but the ROW DATA never does.
// This lane moves the rows, which is the part that actually blocks a migration.
export const MATRIX_LANE = {
    id: 'matrix',
    label: 'Decision Matrix rows',
    nodes: [
        {
            object: 'DecisionMatrixDefinition',
            api: 'tooling',
            key: 'ApiName',
            readOnly: true, // deploy the definition with `sf project deploy` first
            fields: ['ApiName', 'Name', 'Description'],
            refs: {}
        },
        {
            object: 'DecisionMatrixDefinitionVersion',
            api: 'tooling',
            key: 'ApiName',
            fields: ['ApiName', 'DecisionMatrixDefinitionId', 'VersionNumber', 'Status'],
            refs: { DecisionMatrixDefinitionId: 'DecisionMatrixDefinition' },
            parent: 'DecisionMatrixDefinitionId'
        }
    ],
    // Rows live in a per-matrix custom Big Object; the probe resolves the real name.
    rowsVia: 'DecisionMatrixDefinitionVersion'
};

export const LANES = [CONTEXT_LANE, EXPRESSION_LANE, MATRIX_LANE];

export const laneById = (id) => LANES.find((l) => l.id === id);

export const allNodes = () => LANES.flatMap((l) => l.nodes.map((n) => ({ ...n, lane: l.id })));
