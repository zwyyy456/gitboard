import Foundation

enum GraphQLQueries {
    static let sessionProbe = """
        query {
            viewer {
                id
                login
                projectsV2(first: 1) {
                    totalCount
                }
            }
        }
        """

    static let owners = """
        query($after: String) {
            viewer {
                id
                login
                name
                organizations(first: 100, after: $after) {
                    nodes {
                        id
                        login
                        name
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
            }
        }
        """

    static let userProjects = """
        query($after: String) {
            owner: viewer {
                projectsV2(first: 100, after: $after, orderBy: { field: UPDATED_AT, direction: DESC }) {
                    nodes {
                        id
                        title
                        number
                        url
                        viewerCanUpdate
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
            }
        }
        """

    static let organizationProjects = """
        query($login: String!, $after: String) {
            owner: organization(login: $login) {
                projectsV2(first: 100, after: $after, orderBy: { field: UPDATED_AT, direction: DESC }) {
                    nodes {
                        id
                        title
                        number
                        url
                        viewerCanUpdate
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
            }
        }
        """

    static let projectFields = """
        query($id: ID!, $after: String) {
            node(id: $id) {
                ... on ProjectV2 {
                    title
                    number
                    url
                    viewerCanUpdate
                    fields(first: 100, after: $after) {
                        nodes {
                            ... on ProjectV2SingleSelectField {
                                id
                                name
                                options {
                                    id
                                    name
                                    color
                                }
                            }
                        }
                        pageInfo {
                            hasNextPage
                            endCursor
                        }
                    }
                }
            }
        }
        """

    static let projectItems = """
        query($id: ID!, $after: String) {
            node(id: $id) {
                ... on ProjectV2 {
                    items(first: 100, after: $after) {
                        nodes {
                            id
                            content {
                                ... on Issue {
                                    __typename
                                    id
                                    title
                                    number
                                    url
                                    state
                                    assignees(first: 5) {
                                        nodes {
                                            login
                                            avatarUrl
                                            name
                                        }
                                    }
                                    closedByPullRequestsReferences(first: 1) {
                                        nodes {
                                            number
                                            title
                                            url
                                            merged
                                            closed
                                        }
                                    }
                                }
                                ... on PullRequest {
                                    __typename
                                    id
                                    title
                                    number
                                    url
                                    state
                                    assignees(first: 5) {
                                        nodes {
                                            login
                                            avatarUrl
                                            name
                                        }
                                    }
                                }
                                ... on DraftIssue {
                                    __typename
                                    id
                                    title
                                    assignees(first: 5) {
                                        nodes {
                                            login
                                            avatarUrl
                                            name
                                        }
                                    }
                                }
                            }
                            fieldValueByName(name: "Status") {
                                ... on ProjectV2ItemFieldSingleSelectValue {
                                    name
                                    optionId
                                }
                            }
                        }
                        pageInfo {
                            hasNextPage
                            endCursor
                        }
                    }
                }
            }
        }
        """

    static let updateItemStatus = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
            updateProjectV2ItemFieldValue(
                input: {
                    projectId: $projectId
                    itemId: $itemId
                    fieldId: $fieldId
                    value: { singleSelectOptionId: $optionId }
                }
            ) {
                projectV2Item {
                    id
                }
            }
        }
        """

    static let deleteItem = """
        mutation($projectId: ID!, $itemId: ID!) {
            deleteProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
                deletedItemId
            }
        }
        """

    static let searchUsers = """
        query($query: String!) {
            search(query: $query, type: USER, first: 10) {
                nodes {
                    ... on User {
                        login
                        avatarUrl
                        name
                    }
                }
            }
        }
        """

    static let addAssignees = """
        mutation($assignableId: ID!, $assigneeIds: [ID!]!) {
            addAssigneesToAssignable(input: { assignableId: $assignableId, assigneeIds: $assigneeIds }) {
                assignable {
                    ... on Issue {
                        id
                    }
                    ... on PullRequest {
                        id
                    }
                }
            }
        }
        """

    static let removeAssignees = """
        mutation($assignableId: ID!, $assigneeIds: [ID!]!) {
            removeAssigneesFromAssignable(input: { assignableId: $assignableId, assigneeIds: $assigneeIds }) {
                assignable {
                    ... on Issue {
                        id
                    }
                    ... on PullRequest {
                        id
                    }
                }
            }
        }
        """

    static let getUser = """
        query($login: String!) {
            user(login: $login) {
                id
                login
                avatarUrl
                name
            }
        }
        """

    static let addDraftIssue = """
        mutation($projectId: ID!, $title: String!) {
            addProjectV2DraftIssue(input: { projectId: $projectId, title: $title }) {
                projectItem {
                    id
                }
            }
        }
        """

    static let getProjectOwnerAndRepo = """
        query($id: ID!) {
            node(id: $id) {
                ... on ProjectV2 {
                    owner {
                        ... on Organization {
                            login
                            repositories(first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) {
                                nodes {
                                    name
                                    owner {
                                        login
                                    }
                                }
                            }
                        }
                        ... on User {
                            login
                            repositories(first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) {
                                nodes {
                                    name
                                }
                            }
                        }
                    }
                }
            }
        }
        """

    static let addItemToProject = """
        mutation($projectId: ID!, $contentId: ID!) {
            addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
                item {
                    id
                }
            }
        }
        """
}
