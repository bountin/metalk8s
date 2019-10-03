import { call, takeEvery, select } from 'redux-saga/effects';

import * as ApiK8s from '../../services/k8s/api';
import {
  LABEL_COMPONENT,
  LABEL_NAME,
  LABEL_PART_OF,
  LABEL_VERSION,
  SOLUTION_NAME,
  DEPLOYMENT_NAME,
  OPERATOR_NAME
} from '../../constants';
const CREATE_DEPLOYMENT = 'CREATE_DEPLOYMENT';
const EDIT_DEPLOYMENT = 'EDIT_DEPLOYMENT';

// Action Creators
export const createDeploymentAction = () => {
  return { type: CREATE_DEPLOYMENT };
};

export const editDeploymentAction = payload => {
  return { type: EDIT_DEPLOYMENT, payload };
};

// Sagas
export function* fetchOpertorDeployments(namespaces) {
  const result = yield call(
    ApiK8s.getOperatorDeployments,
    namespaces,
    DEPLOYMENT_NAME
  );
  return result;
}

export function* editDeployment(version, name, namespace) {
  const registry_prefix = yield select(
    state => state.config.api.registry_prefix
  );
  const body = operatorDeployment(registry_prefix, version);
  const result = yield call(ApiK8s.updateDeployment, body, namespace, name);
  return result;
}

export function* createDeployment(namespaces, version) {
  const registry_prefix = yield select(
    state => state.config.api.registry_prefix
  );
  const body = operatorDeployment(registry_prefix, version);
  const result = yield call(
    ApiK8s.createNamespacedDeployment,
    namespaces,
    body
  );
  return result;
}

export function* createOrUpdateOperatorDeployment(
  namespaces,
  environment,
  version
) {
  const environments = yield select(state => state.app.environment.list);
  const environmentToUpdate = environments.find(
    env => env.name === environment
  );
  let results;
  if (environmentToUpdate && environmentToUpdate.operator) {
    results = yield call(
      editDeployment,
      version,
      environmentToUpdate.operator.name,
      namespaces
    );
  } else {
    results = yield call(createDeployment, namespaces, version);
  }
  return results;
}

export function* createNamespacedServiceAccount(namespaces) {
  const results = yield call(
    ApiK8s.listNamespacedServiceAccount,
    namespaces,
    DEPLOYMENT_NAME
  );
  if (results.body.items.length === 0) {
    const result = yield call(
      ApiK8s.createNamespacedServiceAccount,
      namespaces,
      serviceAccountBody
    );
    return result;
  }
  return results;
}

export function* createNamespacedRole(namespaces) {
  const results = yield call(
    ApiK8s.listNamespacedRole,
    namespaces,
    DEPLOYMENT_NAME
  );
  if (results.body.items.length === 0) {
    const result = yield call(
      ApiK8s.createNamespacedRole,
      namespaces,
      roleBody
    );
    return result;
  }
  return results;
}

export function* createNamespacedRoleBinding(namespaces) {
  const results = yield call(
    ApiK8s.listNamespacedRoleBinding,
    namespaces,
    DEPLOYMENT_NAME
  );
  if (results.body.items.length === 0) {
    const result = yield call(
      ApiK8s.createNamespacedRoleBinding,
      namespaces,
      roleBindingBody
    );
    return result;
  }
  return results;
}

// Helpers
const operatorImage = (registryPrefix, version) =>
  `${registryPrefix}/${SOLUTION_NAME}-${version}/example-solution-operator:${version}`;

const operatorLabels = version => ({
  app: DEPLOYMENT_NAME,
  [LABEL_NAME]: DEPLOYMENT_NAME,
  [LABEL_VERSION]: version,
  [LABEL_COMPONENT]: 'operator',
  [LABEL_PART_OF]: SOLUTION_NAME
});

const operatorDeployment = (registryPrefix, version) => ({
  apiVersion: 'apps/v1',
  kind: 'Deployment',
  metadata: {
    name: DEPLOYMENT_NAME,
    labels: operatorLabels(version)
  },
  spec: {
    replicas: 1,
    selector: {
      matchLabels: {
        name: OPERATOR_NAME
      }
    },
    template: {
      metadata: {
        labels: {
          name: OPERATOR_NAME
        }
      },
      spec: {
        serviceAccountName: DEPLOYMENT_NAME,
        containers: [
          {
            name: OPERATOR_NAME,
            image: operatorImage(registryPrefix, version),
            command: [DEPLOYMENT_NAME],
            imagePullPolicy: 'Always',
            env: [
              {
                name: 'WATCH_NAMESPACE',
                valueFrom: {
                  fieldRef: {
                    fieldPath: 'metadata.namespace'
                  }
                }
              },
              {
                name: 'POD_NAME',
                valueFrom: {
                  fieldRef: {
                    fieldPath: 'metadata.name'
                  }
                }
              },
              {
                name: 'OPERATOR_NAME',
                value: OPERATOR_NAME
              },
              {
                name: 'REGISTRY_PREFIX',
                value: registryPrefix
              }
            ]
          }
        ]
      }
    }
  }
});

const serviceAccountBody = {
  apiVersion: 'v1',
  kind: 'ServiceAccount',
  metadata: {
    name: DEPLOYMENT_NAME
  }
};
const roleBody = {
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'Role',
  metadata: {
    creationTimestamp: null,
    name: DEPLOYMENT_NAME
  },
  rules: [
    {
      apiGroups: [''],
      resources: [
        'pods',
        'services',
        'endpoints',
        'persistentvolumeclaims',
        'events',
        'configmaps',
        'secrets'
      ],
      verbs: ['*']
    },
    {
      apiGroups: ['apps'],
      resources: ['deployments', 'daemonsets', 'replicasets', 'statefulsets'],
      verbs: ['*']
    },
    {
      apiGroups: ['monitoring.coreos.com'],
      resources: ['servicemonitors'],
      verbs: ['get', 'create']
    },
    {
      apiGroups: ['apps'],
      resourceNames: [DEPLOYMENT_NAME],
      resources: ['deployments/finalizers'],
      verbs: ['update']
    },
    {
      apiGroups: [''],
      resources: ['pods'],
      verbs: ['get']
    },
    {
      apiGroups: ['apps'],
      resources: ['replicasets'],
      verbs: ['get']
    },
    {
      apiGroups: ['example-solution.metalk8s.scality.com'],
      resources: ['*'],
      verbs: ['*']
    }
  ]
};
const roleBindingBody = {
  kind: 'RoleBinding',
  apiVersion: 'rbac.authorization.k8s.io/v1',
  metadata: {
    name: DEPLOYMENT_NAME
  },
  subjects: [
    {
      kind: 'ServiceAccount',
      name: DEPLOYMENT_NAME
    }
  ],
  roleRef: {
    kind: 'Role',
    name: DEPLOYMENT_NAME,
    apiGroup: 'rbac.authorization.k8s.io'
  }
};

export function* deploymentSaga() {
  yield takeEvery(CREATE_DEPLOYMENT, createDeployment);
  yield takeEvery(EDIT_DEPLOYMENT, editDeployment);
}
