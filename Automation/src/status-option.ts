export function findStatusOption<T extends { name: string }>(
    options: T[],
    name: string
): T | undefined {
    return options.find((option) => option.name === name)
        ?? options.find((option) => option.name.toLowerCase() === name.toLowerCase());
}
