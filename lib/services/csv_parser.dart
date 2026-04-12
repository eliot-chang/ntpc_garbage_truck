/// CSV 解析器，支援引號內含逗號和換行的情況
class CsvParser {
  /// 解析 CSV 字串，回傳 List<Map<String, String>>
  /// 第一行為 header
  static List<Map<String, String>> parse(String csvContent) {
    final lines = _splitLines(csvContent);
    if (lines.isEmpty) return [];

    // 解析 header
    final headers = _parseLine(lines.first);
    final results = <Map<String, String>>[];

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;

      final values = _parseLine(line);
      final map = <String, String>{};

      for (int j = 0; j < headers.length && j < values.length; j++) {
        // 將跨行的換行符替換為空格
        map[headers[j]] = values[j].replaceAll('\n', ' ').replaceAll('\r', '');
      }

      // 確保至少有 city 欄位才加入
      if (map.length >= headers.length ~/ 2) {
        results.add(map);
      }
    }

    return results;
  }

  /// 將 CSV 拆成邏輯行（處理引號內的換行）
  static List<String> _splitLines(String content) {
    final lines = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < content.length; i++) {
      final char = content[i];

      if (char == '"') {
        // 檢查轉義引號 ""
        if (inQuotes && i + 1 < content.length && content[i + 1] == '"') {
          buffer.write('""');
          i++;
          continue;
        }
        inQuotes = !inQuotes;
        buffer.write(char);
      } else if (char == '\n' && !inQuotes) {
        final line = buffer.toString().trim();
        if (line.isNotEmpty) {
          lines.add(line);
        }
        buffer.clear();
      } else if (char == '\r') {
        // 忽略 \r
        continue;
      } else {
        buffer.write(char);
      }
    }

    // 最後一行
    final remaining = buffer.toString().trim();
    if (remaining.isNotEmpty) {
      lines.add(remaining);
    }

    return lines;
  }

  /// 解析單行 CSV，處理引號
  static List<String> _parseLine(String line) {
    final result = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (char == ',' && !inQuotes) {
        result.add(buffer.toString().trim());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }

    result.add(buffer.toString().trim());
    return result;
  }
}
