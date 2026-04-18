#!/usr/bin/env node
/**
 * Đọc reports/slither-report.json và xuất reports/slither-summary.vi.md
 * — bảng tóm tắt theo chủ đề + gợi ý (tiếng Việt).
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const JSON_PATH = join(ROOT, 'reports', 'slither-report.json');
const OUT_PATH = join(ROOT, 'reports', 'slither-summary.vi.md');

/** Gom nhiều detector Slither vào một chủ đề hiển thị */
const THEMES = [
  {
    key: 'reentrancy',
    label: 'Reentrancy',
    checks: new Set([
      'reentrancy-no-eth',
      'reentrancy-benign',
      'reentrancy-events',
      'reentrancy-unlimited-gas',
    ]),
    hint:
      'Chuyển cập nhật state (totalTokenIn, usedSymbols, …) lên trước các transfer / external call; tuân thủ checks-effects-interactions; đối chiếu từng hàm với ReentrancyGuard nếu đã dùng.',
  },
  {
    key: 'arbitrary-send',
    label: 'arbitrary-send-erc20',
    checks: new Set(['arbitrary-send-erc20']),
    hint:
      'Cảnh báo chung về transferFrom(buyer, …) — thường chấp nhận được nếu chỉ gọi từ entrypoint đã kiểm soát và logic nghiệp vụ đúng.',
  },
  {
    key: 'divide-multiply',
    label: 'divide-before-multiply',
    checks: new Set(['divide-before-multiply']),
    hint:
      'Xem lại thứ tự nhân/chia để tránh làm tròn sớm; có thể dùng mulDiv (OpenZeppelin) nếu cần độ chính xác.',
  },
  {
    key: 'oracle-return',
    label: 'unused-return (oracle / Chainlink)',
    checks: new Set(['unused-return']),
    hint:
      'latestRoundData trả về roundId, updatedAt, answeredInRound — nên kiểm tra stale price / round hợp lệ nếu yêu cầu production.',
  },
  {
    key: 'events',
    label: 'events-maths',
    checks: new Set(['events-maths']),
    hint:
      'Cân nhắc emit event khi đổi tham số quan trọng (max buy, wallet %, initialize) để indexer/frontend theo dõi.',
  },
  {
    key: 'zero-check',
    label: 'missing-zero-check',
    checks: new Set(['missing-zero-check']),
    hint:
      'Thêm require địa chỉ khác address(0) nếu chuyển tiền/token tới địa chỉ đó là không hợp lệ.',
  },
  {
    key: 'timestamp',
    label: 'timestamp (block.timestamp)',
    checks: new Set(['timestamp']),
    hint:
      'Thời gian on-chain có độ lệch validator ~vài giây — chỉ dùng cho khoảng thời gian dài / anti-bot, không làm seed ngẫu nhiên.',
  },
  {
    key: 'inheritance',
    label: 'missing-inheritance',
    checks: new Set(['missing-inheritance']),
    hint:
      'Contract nên inherit interface tương ứng để đảm bảo đúng chữ ký và hỗ trợ tooling.',
  },
  {
    key: 'redundant',
    label: 'redundant-statements',
    checks: new Set(['redundant-statements']),
    hint:
      'Biểu thức/statement không tác dụng — xóa hoặc thay bằng logic đúng ý định.',
  },
  {
    key: 'events-index',
    label: 'unindexed-event-address',
    checks: new Set(['unindexed-event-address']),
    hint:
      'Có thể thêm indexed cho address trong event để lọc log hiệu quả (trade-off: thêm gas).',
  },
  {
    key: 'unused-var',
    label: 'unused-state',
    checks: new Set(['unused-state']),
    hint:
      'Biến trạng thái không dùng — xóa hoặc dùng đúng mục đích để giảm gas và nhầm lẫn.',
  },
  {
    key: 'immutable',
    label: 'immutable-states',
    checks: new Set(['immutable-states']),
    hint:
      'Biến chỉ gán trong constructor có thể khai báo immutable để tiết kiệm gas.',
  },
  {
    key: 'shadowing',
    label: 'shadowing-local',
    checks: new Set(['shadowing-local']),
    hint:
      'Tham số/local trùng tên với state/function cha — đổi tên cho rõ ràng, tránh bug.',
  },
  {
    key: 'incorrect-exp',
    label: 'incorrect-exp',
    checks: new Set(['incorrect-exp']),
    hint:
      'Thường là false positive trên thư viện (OZ Math) — đối chiếu mã nguồn gốc.',
  },
];

const DEFAULT_HINT =
  'Xem mô tả trong JSON và [tài liệu detector Slither](https://github.com/crytic/slither/wiki/Detector-Documentation).';

function themeForCheck(check) {
  for (const t of THEMES) {
    if (t.checks.has(check)) return t;
  }
  return null;
}

/** Rút gọn nhãn vị trí từ một phần tử AST của Slither (function / variable / contract). */
function locationLabel(el) {
  const rel = el.source_mapping?.filename_relative || '';
  if (!rel.startsWith('contracts/') || rel.includes('node_modules')) return null;

  if (el.type === 'function') {
    const c = el.type_specific_fields?.parent?.name;
    if (c && el.name) return `${c}.${el.name}`;
    return null;
  }
  if (el.type === 'variable') {
    const parent = el.type_specific_fields?.parent;
    if (parent?.type === 'function') {
      const c = parent.type_specific_fields?.parent?.name;
      const fn = parent.name;
      if (c && fn) return `${c}.${fn}`;
    }
    if (parent?.type === 'contract') {
      return `${parent.name}.${el.name}`;
    }
    return null;
  }
  if (el.type === 'contract') {
    return el.name;
  }
  if (el.type === 'event') {
    const c = el.type_specific_fields?.parent?.name;
    if (c && el.name) return `${c}.${el.name}`;
  }
  return null;
}

function collectLocations(detector) {
  const locs = new Set();
  for (const el of detector.elements || []) {
    const label = locationLabel(el);
    if (label) locs.add(label);
  }
  return [...locs].sort();
}

function escapeCell(s) {
  return String(s).replace(/\|/g, '\\|').replace(/\n/g, '<br>');
}

function main() {
  if (!existsSync(JSON_PATH)) {
    console.error(`Thiếu file: ${JSON_PATH}`);
    console.error('Chạy trước: npm run slither:json');
    process.exit(1);
  }

  const raw = readFileSync(JSON_PATH, 'utf8');
  const data = JSON.parse(raw);
  const detectors = data?.results?.detectors;
  if (!Array.isArray(detectors)) {
    console.error('JSON không có results.detectors');
    process.exit(1);
  }

  /** themeKey -> { label, hint, checks: Set, locations: Set } */
  const buckets = new Map();
  /** check id chưa gán theme -> locations */
  const orphanChecks = new Map();

  for (const d of detectors) {
    const check = d.check;
    if (!check) continue;

    const locs = collectLocations(d);
    const t = themeForCheck(check);

    if (t) {
      if (!buckets.has(t.key)) {
        buckets.set(t.key, {
          label: t.label,
          hint: t.hint,
          slitherChecks: new Set(),
          locations: new Set(),
        });
      }
      const b = buckets.get(t.key);
      b.slitherChecks.add(check);
      locs.forEach((x) => b.locations.add(x));
    } else {
      if (!orphanChecks.has(check)) orphanChecks.set(check, new Set());
      locs.forEach((x) => orphanChecks.get(check).add(x));
    }
  }

  // Các detector không có trong THEMES → bucket "Khác" theo từng check
  for (const [check, locSet] of orphanChecks) {
    const key = `other-${check}`;
    buckets.set(key, {
      label: check,
      hint: DEFAULT_HINT,
      slitherChecks: new Set([check]),
      locations: locSet,
    });
  }

  const rows = [...buckets.values()].sort((a, b) =>
    a.label.localeCompare(b.label, 'vi'),
  );

  const generated = new Date().toISOString();
  let md = `# Slither — tóm tắt theo chủ đề (tiếng Việt)\n\n`;
  md += `_Tạo tự động từ \`reports/slither-report.json\` — ${generated}_\n\n`;
  md += `| Chủ đề | Phạm vi (hợp đồng.hàm) | Gợi ý |\n`;
  md += `| --- | --- | --- |\n`;

  for (const r of rows) {
    const scope =
      r.locations.size > 0
        ? [...r.locations].join(', ')
        : '— (xem mô tả trong JSON)';
    md += `| **${escapeCell(r.label)}** | ${escapeCell(scope)} | ${escapeCell(r.hint)} |\n`;
  }

  md += `\n---\n\n`;
  md += `**Detector Slither gốc (theo nhóm trên):**  \n`;
  for (const r of rows) {
    const checks = [...r.slitherChecks].sort().join(', ');
    md += `- **${r.label}:** \`${checks}\`\n`;
  }

  mkdirSync(dirname(OUT_PATH), { recursive: true });
  writeFileSync(OUT_PATH, md, 'utf8');
  console.log(`Đã ghi: ${OUT_PATH}`);
}

main();
