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
                            ... on ProjectV2Field {
                                id
                                name
                                dataType
                                isIssueField
                            }
                            ... on ProjectV2SingleSelectField {
                                id
                                name
                                dataType
                                isIssueField
                                options {
                                    id
                                    name
                                    color
                                }
                            }
                            ... on ProjectV2IterationField {
                                id
                                name
                                dataType
                                isIssueField
                                configuration {
                                    iterations { id title startDate duration }
                                    completedIterations { id title startDate duration }
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
                                    updatedAt
                                    assignees(first: 100) {
                                        nodes {
                                            login
                                            avatarUrl
                                            name
                                        }
                                    }
                                    labels(first: 100) {
                                        nodes { id name color }
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
                                    subIssuesSummary {
                                        completed
                                        total
                                    }
                                    blockedBy(first: 1) { totalCount }
                                    blocking(first: 1) { totalCount }
                                }
                                ... on PullRequest {
                                    __typename
                                    id
                                    title
                                    number
                                    url
                                    state
                                    updatedAt
                                    isDraft
                                    mergeable
                                    reviewDecision
                                    reviewRequests(first: 20) {
                                        nodes {
                                            requestedReviewer {
                                                ... on User { login }
                                            }
                                        }
                                    }
                                    statusCheckRollup { state }
                                    assignees(first: 100) {
                                        nodes {
                                            login
                                            avatarUrl
                                            name
                                        }
                                    }
                                    labels(first: 100) {
                                        nodes { id name color }
                                    }
                                }
                                ... on DraftIssue {
                                    __typename
                                    id
                                    title
                                    updatedAt
                                    assignees(first: 100) {
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
                            fieldValues(first: 100) {
                                nodes {
                                    __typename
                                    ... on ProjectV2ItemFieldSingleSelectValue {
                                        name
                                        optionId
                                        field { ... on ProjectV2SingleSelectField { id } }
                                    }
                                    ... on ProjectV2ItemFieldIterationValue {
                                        title
                                        iterationId
                                        field { ... on ProjectV2IterationField { id } }
                                    }
                                    ... on ProjectV2ItemFieldDateValue {
                                        date
                                        field { ... on ProjectV2Field { id } }
                                    }
                                    ... on ProjectV2ItemFieldNumberValue {
                                        number
                                        field { ... on ProjectV2Field { id } }
                                    }
                                    ... on ProjectV2ItemFieldTextValue {
                                        text
                                        field { ... on ProjectV2Field { id } }
                                    }
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

    static let itemDetail = """
        query($id: ID!) {
            node(id: $id) {
                __typename
                ... on Issue {
                    id
                    bodyHTML
                    createdAt
                    updatedAt
                    author { login avatarUrl }
                    viewerCanUpdate
                    viewerCanSetMilestone
                    repository { nameWithOwner }
                    milestone {
                        id
                        number
                        title
                        dueOn
                        state
                        progressPercentage
                    }
                    parent {
                        id
                        number
                        title
                        url
                        state
                        repository { nameWithOwner }
                    }
                    subIssues(first: 100) {
                        nodes {
                            id
                            number
                            title
                            url
                            state
                            repository { nameWithOwner }
                        }
                    }
                    subIssuesSummary { completed total }
                    blockedBy(first: 50) {
                        nodes {
                            id
                            number
                            title
                            url
                            state
                            repository { nameWithOwner }
                        }
                    }
                    blocking(first: 50) {
                        nodes {
                            id
                            number
                            title
                            url
                            state
                            repository { nameWithOwner }
                        }
                    }
                }
                ... on PullRequest {
                    id
                    bodyHTML
                    createdAt
                    updatedAt
                    author { login avatarUrl }
                }
                ... on DraftIssue {
                    id
                    bodyHTML
                    createdAt
                    updatedAt
                    creator { login avatarUrl }
                }
            }
        }
        """

    static let repositoryMilestones = """
        query($owner: String!, $name: String!, $after: String) {
            repository(owner: $owner, name: $name) {
                milestones(
                    first: 100
                    after: $after
                    states: OPEN
                    orderBy: { field: DUE_DATE, direction: ASC }
                ) {
                    nodes {
                        id
                        number
                        title
                        dueOn
                        state
                        progressPercentage
                    }
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                }
            }
        }
        """

    static let setIssueMilestone = """
        mutation($issueId: ID!, $milestoneId: ID!) {
            updateIssue(input: { id: $issueId, milestoneId: $milestoneId }) {
                issue { id }
            }
        }
        """

    static let clearIssueMilestone = """
        mutation($issueId: ID!) {
            updateIssue(input: { id: $issueId, milestoneId: null }) {
                issue { id }
            }
        }
        """

    static let addSubIssue = """
        mutation($issueId: ID!, $subIssueId: ID!) {
            addSubIssue(input: { issueId: $issueId, subIssueId: $subIssueId }) {
                issue { id }
            }
        }
        """

    static let replaceSubIssueParent = """
        mutation($issueId: ID!, $subIssueId: ID!) {
            addSubIssue(input: {
                issueId: $issueId
                subIssueId: $subIssueId
                replaceParent: true
            }) {
                issue { id }
            }
        }
        """

    static let removeSubIssue = """
        mutation($issueId: ID!, $subIssueId: ID!) {
            removeSubIssue(input: { issueId: $issueId, subIssueId: $subIssueId }) {
                issue { id }
            }
        }
        """

    static let addBlockedBy = """
        mutation($issueId: ID!, $blockingIssueId: ID!) {
            addBlockedBy(input: { issueId: $issueId, blockingIssueId: $blockingIssueId }) {
                issue { id }
            }
        }
        """

    static let removeBlockedBy = """
        mutation($issueId: ID!, $blockingIssueId: ID!) {
            removeBlockedBy(input: { issueId: $issueId, blockingIssueId: $blockingIssueId }) {
                issue { id }
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

    static let updateIterationField = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
            updateProjectV2ItemFieldValue(input: {
                projectId: $projectId
                itemId: $itemId
                fieldId: $fieldId
                value: { iterationId: $iterationId }
            }) { projectV2Item { id } }
        }
        """

    static let updateDateField = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $date: Date!) {
            updateProjectV2ItemFieldValue(input: {
                projectId: $projectId
                itemId: $itemId
                fieldId: $fieldId
                value: { date: $date }
            }) { projectV2Item { id } }
        }
        """

    static let updateNumberField = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $number: Float!) {
            updateProjectV2ItemFieldValue(input: {
                projectId: $projectId
                itemId: $itemId
                fieldId: $fieldId
                value: { number: $number }
            }) { projectV2Item { id } }
        }
        """

    static let updateTextField = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $text: String!) {
            updateProjectV2ItemFieldValue(input: {
                projectId: $projectId
                itemId: $itemId
                fieldId: $fieldId
                value: { text: $text }
            }) { projectV2Item { id } }
        }
        """

    static let clearItemField = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!) {
            clearProjectV2ItemFieldValue(input: {
                projectId: $projectId
                itemId: $itemId
                fieldId: $fieldId
            }) { projectV2Item { id } }
        }
        """

    static let archiveItem = """
        mutation($projectId: ID!, $itemId: ID!) {
            archiveProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
                item { id }
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

    static let addDraftIssue = """
        mutation($projectId: ID!, $title: String!, $body: String!) {
            addProjectV2DraftIssue(input: { projectId: $projectId, title: $title, body: $body }) {
                projectItem {
                    id
                }
            }
        }
        """

    static let searchItems = """
        query($searchQuery: String!) {
            search(query: $searchQuery, type: ISSUE, first: 20) {
                nodes {
                    ... on Issue {
                        __typename
                        id
                        title
                        number
                        url
                        repository { nameWithOwner }
                    }
                    ... on PullRequest {
                        __typename
                        id
                        title
                        number
                        url
                        repository { nameWithOwner }
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
