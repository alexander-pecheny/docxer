using System.Text.Json;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;

var format = FileFormatVersions.Office2019;
var json = false;
var files = new List<string>();
for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--json": json = true; break;
        case "--format" when i + 1 < args.Length:
            if (!Enum.TryParse(args[++i], out format)) return Usage($"unknown format {args[i]}");
            break;
        case "-h" or "--help": return Usage(null);
        default: files.Add(args[i]); break;
    }
}
if (files.Count == 0) return Usage("no files given");

var failed = false;
var validator = new OpenXmlValidator(format);
foreach (var path in files)
{
    List<Error> errors;
    try
    {
        using var doc = WordprocessingDocument.Open(path, false);
        errors = validator.Validate(doc)
            .Select(e => new Error(e.Part?.Uri.ToString(), e.Path?.XPath, e.Description, e.Id))
            .ToList();
    }
    catch (Exception e)
    {
        failed = true;
        if (json) Console.WriteLine(JsonSerializer.Serialize(new { path, ok = false, exception = e.Message, errors = Array.Empty<Error>() }));
        else Console.WriteLine($"{path}: failed to open: {e.Message}");
        continue;
    }
    failed |= errors.Count > 0;
    if (json)
    {
        Console.WriteLine(JsonSerializer.Serialize(new { path, ok = errors.Count == 0, errors }));
        continue;
    }
    Console.WriteLine(errors.Count == 0 ? $"{path}: OK" : $"{path}: {errors.Count} errors");
    foreach (var e in errors.Take(20))
        Console.WriteLine($"  {e.part} {e.path}: {e.description}");
}
return failed ? 1 : 0;

static int Usage(string? error)
{
    if (error != null) Console.Error.WriteLine($"error: {error}");
    Console.Error.WriteLine($"usage: ooxml-validate [--format {string.Join('|', Enum.GetNames<FileFormatVersions>().Where(n => n.StartsWith("Office") || n == "Microsoft365"))}] [--json] file.docx...");
    return 2;
}

record Error(string? part, string? path, string description, string id);
