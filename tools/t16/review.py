"""Verify the local run matrix and render a self-contained Korean listening worksheet."""
import argparse
from html import escape
import math
from pathlib import Path
import re
from urllib.parse import urlsplit

from compare import CANDIDATES, RATE, file_digest, read, save

NAMES = {"wk-large": "WhisperKit · large-v3", "wk-turbo": "WhisperKit · large-v3-turbo",
         "cpp-large": "whisper.cpp · large-v3", "cpp-turbo": "whisper.cpp · large-v3-turbo"}
RUBRIC = (
    ("한국어 본문", 40, "발화를 듣고 의미 단위별로 맞은 수 / 확인한 수를 기록합니다."),
    ("영어·전공 용어", 25, "들리는 용어의 각 출현을 세고 올바르게 보존된 수 / 출현 수를 기록합니다."),
    ("환각·반복·누락", 20, "검토한 창 중 해당 오류가 없는 창의 비율을 기록합니다. 사건 종류·횟수·영향·원본 시각을 함께 적습니다."),
    ("지연·대기열", 10, "제출→첫 partial ≤3초, 첫 partial ≤5초, final ≤3초인 창의 비율 세 개와 "
     "RTF ≤0.83인 샘플 비율, 마지막 모의 대기 ≤1초인 샘플 비율의 평균입니다. 미관측 partial은 목표 미달입니다."),
    ("메모리·안정성", 5, "샘플별 완주, 오류·재시도·경고 없음, peak footprint ≤물리 메모리의 50% 등 세 조건의 달성 비율입니다."),
)


def stamp(seconds):
    return f"{int(seconds) // 60:02}:{seconds % 60:06.3f}"


def quantile(values, p):
    return sorted(values)[math.ceil(len(values) * p) - 1] if values else None


def stats(plan, rows):
    final_frames = 0
    empty_finals = 0
    total_service = []
    partial, final, queue = [], [], []
    finish, waits = 0., []
    valid_simulation = True
    if len(rows) != len(plan["windows"]):
        raise ValueError("expected a row or explicit missing entry for every window")
    for win, row in zip(plan["windows"], rows):
        if row is None:
            valid_simulation = False
            continue
        term = row.get("terminal", {})
        if term.get("kind") == "final":
            final_frames += win["endFrame"] - win["startFrame"]
            if not any(s["text"].strip() for s in term["segments"]):
                empty_finals += 1
            final.append(row["terminalSeconds"])
            if "timing" in row:
                total_service.append(row["timing"]["inferenceSeconds"])
        if "firstPartialSeconds" in row:
            partial.append(row["firstPartialSeconds"])
        if "timing" in row:
            queue.append(row["timing"]["queueSeconds"])
        service = row.get("serviceSeconds")
        if service is None:
            valid_simulation = False
        if valid_simulation:
            arrival = win["endFrame"] / RATE
            wait = max(0, finish - arrival)
            waits.append(wait)
            finish = arrival + wait + service
    count = len(rows)
    return dict(finalFrames=final_frames, frames=plan["frameCount"], completeWindows=len(final), emptyFinals=empty_finals,
                windows=count, rtf=(sum(total_service) / (plan["frameCount"] / RATE)
                                    if len(total_service) == count else None),
                partialP50=quantile(partial, .50), partialP95=quantile(partial, .95),
                partialCount=len(partial), partialWithin3=sum(x <= 3 for x in partial),
                partialWithin5=sum(x <= 5 for x in partial), finalWithin3=sum(x <= 3 for x in final),
                finalP50=quantile(final, .50), finalP95=quantile(final, .95),
                actualQueueMax=max(queue, default=None), simWaitMax=max(waits) if valid_simulation else None,
                simWaitLast=waits[-1] if valid_simulation else None)


def checked_run(root, job, plan):
    directory = root / job["sample"] / job["candidate"]
    result = read(directory / "run.json") if (directory / "run.json").exists() else {}
    descriptor = read(CANDIDATES[job["candidate"]])["entries"][0]
    if job["checksum"] != descriptor["model"]["checksum"] or job["pcmSHA256"] != plan["pcmSHA256"]:
        raise ValueError("plan differs from the predeclared matrix")
    if result and (result["pcmSHA256"] != plan["pcmSHA256"] or result["sourceSHA256"] != plan["sourceSHA256"]
                   or result["frameCount"] != plan["frameCount"] or result["model"]["model"]["checksum"] != job["checksum"]
                   or result["settings"]["languageMode"] != plan["languageMode"]):
        raise ValueError("run identity differs from the plan")
    if result and (result["model"] != descriptor or result["settings"]["model"]["options"] != dict(
            temperature=0, partialResults=True, timestamps=True, computeMode=descriptor["compute"])):
        raise ValueError("candidate settings differ from the frozen protocol")
    rows = []
    for i, win in enumerate(plan["windows"]):
        path = directory / f"window-{i}.json"
        row = read(path) if path.exists() else None
        if row and (row["window"] != win or row["index"] != i):
            raise ValueError("unexpected window boundaries, order or content")
        if row and "terminal" in row:
            ctx = row["terminal"]["context"]
            expected_ms = (win["startFrame"] + 8) // 16
            if (ctx["sequence"] != i or ctx["mediaStart"] != expected_ms
                    or ctx["mediaEnd"] != expected_ms + (win["endFrame"] - win["startFrame"] + 8) // 16
                    or ctx["session"]["model"]["model"]["checksum"] != job["checksum"]
                    or result and ctx["session"] != result["settings"]):
                raise ValueError("terminal provenance or restored sample time differs")
        rows.append(row)
    if len(list(directory.glob("window-*.json"))) != sum(row is not None for row in rows):
        raise ValueError("unexpected window outputs")
    summary = stats(plan, rows)
    if result and result["completedWindows"] != summary["completeWindows"]:
        raise ValueError("incorrect final count")
    exit_path = directory.with_name(directory.name + "-exit.json")
    code = read(exit_path)["returncode"] if exit_path.is_file() else None
    hardware = result.get("hardware", "")
    physical = hardware.rpartition("physicalMemory=")[2]
    summary.update(hardware=hardware, physicalMemory=int(physical) if physical.isdecimal() else None, exitCode=code, loadSeconds=result.get("loadSeconds"), loadTiming=result.get("loadTiming"),
                   effectiveCompute=result.get("effectiveCompute"), baseline=result.get("baselinePhysicalFootprint"),
                   peak=result.get("peakPhysicalFootprint"), warnings=result.get("warnings", []),
                   error=result.get("failure"), missingWindowIndices=[i for i, row in enumerate(rows) if row is None],
                   failedWindowIndices=[i for i, row in enumerate(rows) if row and row.get("failure")],
                   complete=code == 0 and summary["completeWindows"] == len(rows) and bool(result))
    if not summary["complete"]:
        summary["rtf"] = None
    return rows, summary


def num(number):
    return f"{number:.3f}" if number is not None else "—"


def table(head, body):
    return ("<table><thead><tr>" + "".join(f"<th>{h}</th>" for h in head) + "</tr></thead><tbody>" +
            "".join("<tr>" + "".join(f"<td>{c}</td>" for c in row) + "</tr>" for row in body) + "</tbody></table>")


def link(path, title):
    return f'<a href="{escape(str(path), quote=True)}">{escape(title)}</a>'


def source_credit(directory):
    path = directory / "attribution.json"
    if not path.is_file():
        return directory.name, ""
    source = read(path)
    for url in (source["source"], source["licenseURL"], source.get("notesURL", source["source"])):
        if urlsplit(url).scheme != "https":
            raise ValueError("expected HTTPS provenance link")
    credits = (escape(source["artist"]) + " · " + link(source["source"], "배포처 원본") + " · " +
               link(source["licenseURL"], source["license"]) + "<br>" + escape(source["modification"]))
    if source.get("reviewTerms"):
        credits += ("<br>발표 자료에 나온 청취 참고어 · " + escape(", ".join(source["reviewTerms"])) +
                    " · " + link(source.get("notesURL", source["source"]), "자료 출처"))
    return source["title"], "<p>" + credits + "</p>"


def terminology_example(results, representative):
    """Locate a listening example. Differences between finals are not a reference transcript."""
    best, largest = None, 0
    for index, candidates in enumerate(zip(*results.values())):
        if index in representative or any(not row or row.get("terminal", {}).get("kind") != "final" for row in candidates):
            continue
        vocabularies = []
        for row in candidates:
            text = "".join(segment["text"] for segment in row["terminal"]["segments"])
            vocabularies.append(set(re.findall(r"[A-Za-z][A-Za-z0-9.+#-]*", text.casefold())))
        differences = len(set.union(*vocabularies) - set.intersection(*vocabularies))
        if differences > largest:
            best, largest = index, differences
    return best


def render(root):
    matrix = read(root / "matrix.json")
    paths = sorted(root.glob("sample-*/plan.json"))
    if not paths or (not matrix["synthetic"] and len(paths) < 3):
        raise ValueError("missing comparison samples")
    pairs = [(j["sample"], j["candidate"]) for j in matrix["jobs"]]
    if len(set(pairs)) != len(pairs) or set(pairs) != {(p.parent.name, n) for p in paths for n in NAMES}:
        raise ValueError("missing, duplicate or unknown matrix job")
    panels, summaries, navigation, raw = [], [], [], {}
    inference_times = {candidate: [] for candidate in NAMES}
    for path in paths:
        directory, plan = path.parent.name, read(path)
        if file_digest(path.parent / "audio.f32") != plan["pcmSHA256"] or file_digest(Path(plan["source"])) != plan["sourceSHA256"]:
            raise ValueError("source or PCM changed")
        from_wave = path.parent / "listen.wav"
        if not from_wave.is_file():
            raise ValueError("missing listening copy")
        sample_title, credits = source_credit(path.parent)
        navigation.append(link("#" + directory, sample_title))
        results, raw[directory] = {}, {}
        for job in matrix["jobs"]:
            name = job["candidate"]
            if job["sample"] != directory:
                continue
            rows, s = checked_run(root, job, plan)
            inference_times[name].extend(row["timing"]["inferenceSeconds"] for row in rows if row and "timing" in row)
            raw[directory][name] = s
            results[name] = rows
            out = f"{directory}/{name}"
            detail = link(out + "/run.json", "측정") if (root / out / "run.json").exists() else "측정 누락"
            if (root / (out + ".log")).exists():
                detail += " · " + link(out + ".log", "로그")
            errors = [*s["warnings"], *([s["error"]] if s["error"] else [])]
            summaries.append([link("#" + directory, sample_title), NAMES[name], ("완주" if s["complete"] else "미완주") +
                f' {s["completeWindows"]}/{s["windows"]} · {100 * s["finalFrames"] / s["frames"]:.1f}%',
                num(s["rtf"]), num(s["loadSeconds"]), f'{num(s["partialP50"])} / {num(s["partialP95"])} ({s["partialCount"]}/{s["windows"]})',
                f'{num(s["finalP50"])} / {num(s["finalP95"])}', num(s["actualQueueMax"]),
                f'{num(s["simWaitMax"])} / {num(s["simWaitLast"])}',
                " / ".join(num(s[k] / (1024**3) if s[k] is not None else None) for k in ("baseline", "peak")),
                detail + (" · " + escape(", ".join(errors)) if errors else "")])
        def transcript_row(index):
            win = plan["windows"][index]
            start, end = (win[k] / RATE for k in ("startFrame", "endFrame"))
            row = [f'<button data-start="{start}" data-end="{end}">▶ {stamp(start)}–{stamp(end)}</button><br>'
                   f'원본 {stamp(plan["sourceStartMs"] / 1000 + start)}']
            for name in NAMES:
                r = results[name][index]
                if r is None:
                    row.append("미실행 / 기록 누락")
                    continue
                segments = r.get("terminal", {}).get("segments", [])
                text = "".join(seg["text"] for seg in segments).strip()
                desc = text or ("빈 final" if r.get("terminal", {}).get("kind") == "final" else "")
                row.append(escape(desc) + (" · " + escape(r["failure"]) if r.get("failure") else "") +
                           "<br>" + link(f"{directory}/{name}/window-{index}.json", "구간 측정"))
            return row
        cols = ["같은 원음"] + list(NAMES.values())
        title = f"{escape(sample_title)} · {stamp(plan['frameCount'] / RATE)}"
        additional = next((i for i in range(len(plan["windows"])) if i not in plan["reviewIndices"] and
                           any(rows[i] is None or rows[i].get("failure") for rows in results.values())), None)
        example = ("" if additional is None else "<details><summary>추가 청취 · 실패가 발생한 첫 구간</summary>" +
                   table(cols, [transcript_row(additional)]) + "</details>")
        english = terminology_example(results, plan["reviewIndices"])
        if english is not None:
            example += ("<details><summary>추가 청취 · 영문 표기가 가장 많이 갈린 구간</summary>"
                        "<p>네 후보 모두 final을 낸 구간 중 영문 단어 집합의 차이가 가장 큰 사례입니다. "
                        "어떤 표기가 원음에 맞는지 들어 보세요.</p>" + table(cols, [transcript_row(english)]) + "</details>")
        panels.append(f'<section id="{escape(directory)}"><h2>{title}</h2>' + credits + '<p>' + link(Path(plan["source"]).as_uri(), "로컬 원본 파일") + " · " +
            link(f"{directory}/plan.json", "구간표·해시") + '</p><audio controls preload="none" src="' +
            escape(directory, quote=True) + '/listen.wav"></audio><h3>사전 선정한 초·중·후반</h3>' +
            table(cols, map(transcript_row, plan["reviewIndices"])) + example + '<details><summary>전체 구간 전사와 측정</summary>' +
            table(cols, map(transcript_row, range(len(plan["windows"])))) + '</details></section>')
    observed_hosts = {s["hardware"] for cases in raw.values() for s in cases.values() if s["hardware"]}
    if len(observed_hosts) > 1:
        raise ValueError("multiple host configurations")
    overview = table(["샘플", "후보", "final 창 / 전체 · 프레임", "RTF", "로드 s", "partial p50 / p95 s (관측)",
                      "final p50 / p95 s", "엔진 대기 최대 s", "모의 대기 최대 / 마지막 s", "기준 / peak GiB", "상세"], summaries)
    evaluation = table(["평가 항목", "비중", "동일한 평가 기준"], [(label, str(w), note) for label, w, note in RUBRIC])
    marker = "합성 검증용" if matrix["synthetic"] else "강의 비교"
    candidate_notes = []
    scores = {}
    for name in NAMES:
        records = [sample[name] for sample in raw.values()]
        rtfs = [s["rtf"] for s in records if s["rtf"] is not None]
        peaks = [s["peak"] / (1024**3) for s in records if s["peak"] is not None]
        total = sum(s["windows"] for s in records)
        ratios = [sum(s[k] for s in records) / total for k in ("partialWithin3", "partialWithin5", "finalWithin3")]
        if len(rtfs) == len(records) and all(s["simWaitLast"] is not None for s in records):
            ratios += [sum(r <= .83 for r in rtfs) / len(records),
                       sum(s["simWaitLast"] <= 1 for s in records) / len(records)]
            latency = sum(ratios)  # Five 0–1 ratios produce the 0–5 item score.
        else:
            latency = None
        stability = None
        if all(s["peak"] is not None and s["physicalMemory"] for s in records):
            successes = sum(s["complete"] for s in records)
            clean = sum(s["complete"] and not s["warnings"] for s in records)
            fit = sum(s["peak"] <= s["physicalMemory"] / 2 for s in records)
            stability = 5 * (successes + clean + fit) / (3 * len(records))
        scores[name] = [None, None, None, latency, stability]
        candidate_notes.append([NAMES[name], f'{sum(s["complete"] for s in records)}/{len(records)}',
            f'{sum(s["completeWindows"] for s in records)}/{total}', str(sum(s["emptyFinals"] for s in records)),
            " / ".join(num(s["rtf"]) for s in records),
            f'{num(quantile(inference_times[name], .5))} ({len(inference_times[name])}/{total})',
            num(max(peaks, default=None)),
            "토큰 진행 콜백" if name.startswith("wk") else "완성된 세그먼트 콜백"])
    cards = table(["후보", "완주 강의", "final / 전체 구간", "빈 final", "강의별 RTF (목표 ≤0.83)",
                   "시도당 추론 중앙값 s · 실패 포함 (관측)", "peak GiB", "partial 단위"], candidate_notes)
    html = f'''<!doctype html><html lang="ko"><meta charset="utf-8"><title>T16 {marker}</title>
<style>body{{font:16px system-ui,sans-serif;line-height:1.55;color:#172a32;margin:2rem}}section{{margin:3rem 0;scroll-margin-top:1rem}}
table{{width:100%;border-collapse:collapse;font-size:.9rem;margin:1rem 0}}th,td{{border:1px solid #bfcacb;padding:.55rem;text-align:left;vertical-align:top}}
th{{background:#e6efed}}button,summary{{cursor:pointer}}audio{{width:min(100%,48rem)}}details{{margin:1rem 0}} a{{color:#126254}}
section table{{table-layout:fixed}}section th:first-child{{width:10rem}}section td{{overflow-wrap:anywhere}}section td a{{font-size:.78rem}}
button{{padding:.4rem;color:inherit}}nav a{{display:inline-block;margin:0 1rem .4rem 0}}@media(max-width:850px){{section table{{table-layout:auto;min-width:820px}}section{{overflow:auto}}body{{margin:1rem}}}}</style>
<h1>T16 {marker}</h1><p>구간 버튼을 누르면 네 전사에 해당하는 동일한 PCM을 재생합니다. 원본 파일의 시각도 함께 표시합니다.</p>
<p>빈 final은 엔진이 글자 없이 정상 종료한 구간입니다. 원음에서 무음인지 발화가 빠졌는지 확인할 수 있습니다.</p>
<nav>{' '.join(navigation)}</nav>{cards}<details><summary>샘플별 지연·메모리·실패 기록 및 측정 방법</summary>{overview}<p>1회 순차 실행, 별도 워밍업·재시도 0회. 로드와 모델 prewarm은 처리율에서 제외합니다.
RTF = 완주한 창들의 총 추론 초 / 전체 오디오 초. 지연은 창 제출 시점 기준이며, partial 미관측과 미완주 RTF는 —입니다.
모의 유입은 각 창의 끝 시각에 도착한다고 가정합니다. 시작 = max(도착, 이전 종료), 종료 = 시작 + 서비스 시간.
50ms마다 측정한 프로세스 physical footprint는 짧은 피크와 GPU·ANE 사용량 일부를 놓칠 수 있습니다.
마이크 발화 기준 3초·5초 지연과 2시간 라이브 대기열은 별도 검증 항목입니다.</p></details>
{''.join(panels)}<h2>청취 평가</h2>{evaluation}
<p>대표 구간만 공통 분모에 넣고 추가 사례는 원본 시각과 함께 따로 적습니다.
항목 점수(0~5) = 5 × 달성 비율. 전체 점수 = Σ(항목 점수 / 5 × 비중).
미평가·분모 0은 공란으로 두며 전체 점수·순위도 보류합니다.</p>
<p><a href="ratings.tsv">로컬 채점표</a> · <a href="summary.json">원값 요약</a> · <a href="matrix.json">실행 목록</a></p>
<script>document.querySelectorAll("section").forEach(section=>{{
const player=section.querySelector("audio");let end=null;
player.addEventListener("timeupdate",()=>{{if(end!==null && player.currentTime>=end){{player.pause();end=null}}}});
section.addEventListener("click",e=>{{const b=e.target.closest("button");if(!b)return;
document.querySelectorAll("audio").forEach(p=>p.pause());end=Number(b.dataset.end);player.currentTime=Number(b.dataset.start);player.play()}});
}})</script></html>'''
    with (root / "ratings.tsv").open("x") as sheet:
        sheet.write("후보\t항목\t비중\t샘플·원본 시각\t분자\t분모\t점수(0-5)\t관찰·영향·근거\n")
        for key, name in NAMES.items():
            for (label, weight, _), score in zip(RUBRIC, scores[key]):
                value = "" if score is None else f"{score:.3f}"
                sheet.write(f"{name}\t{label}\t{weight}\t\t\t\t{value}\t\n")
    save(root / "summary.json", raw)
    with (root / "REVIEW.html").open("x") as file:
        file.write(html)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    render(parser.parse_args().directory.resolve())
