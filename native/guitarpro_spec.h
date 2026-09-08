#pragma once

namespace guitarpro {
inline QJsonObject semanticSpecSchema() {
    const QJsonObject text{{"type", "string"}}, flag{{"type", "boolean"}}, number{{"type", "number"}}, object{{"type", "object"}};
    const auto integer = [](int low, int high) { return QJsonObject{{"type", "integer"}, {"minimum", low}, {"maximum", high}}; };
    const auto array = [](const QJsonObject &items, int low, int high) { return QJsonObject{{"type", "array"}, {"items", items}, {"minItems", low}, {"maxItems", high}}; };
    const auto record = [](const QJsonObject &properties, const QJsonArray &required = QJsonArray()) {
        return QJsonObject{{"type", "object"}, {"properties", properties}, {"required", required}, {"additionalProperties", false}};
    };
    const auto nullable = [](const QJsonObject &type) { return QJsonObject{{"anyOf", QJsonArray{type, QJsonObject{{"type", "null"}}}}}; };
    auto note = record({{"string", integer(0, 11)}, {"fret", integer(0, 36)}, {"midi", integer(0, 127)}, {"sounding_midi", integer(0, 127)},
        {"accidental", nullable(integer(-3, 2))}, {"effects", object}, {"tie", record({{"origin", flag}, {"destination", flag}})}});
    note["anyOf"] = QJsonArray{QJsonObject{{"required", QJsonArray{"string", "fret"}}}, QJsonObject{{"required", QJsonArray{"midi"}}}};
    const auto rhythm = QJsonObject{{"type", "integer"}, {"enum", QJsonArray{1,2,4,8,16,32,64,128}}};
    const auto beat = record({{"denominator", rhythm}, {"dots", integer(0, 2)}, {"rest", flag}, {"notes", array(note, 0, 32)},
        {"tuplets", object}, {"effects", object}, {"text", text}, {"chord", nullable(object)},
        {"lyrics", array(record({{"line", integer(0,4)}, {"text", text}}, {"line", "text"}), 0, 5)},
        {"legato", record({{"origin", flag}, {"destination", flag}})}});
    const auto bar = record({{"voices", array(record({{"beats", array(beat, 0, 20000)}}, {"beats"}), 0, 4)}}, {"voices"});
    const auto staff = record({{"tuning", array(integer(0,127), 1, 12)}, {"capo", integer(0,24)}, {"partial_capo", integer(0,24)},
        {"partial_capo_strings", array(flag, 1, 12)}, {"bars", array(bar, 1, 256)}}, {"bars"});
    const auto track = record({{"name", text}, {"short_name", text}, {"template", text}, {"source_track", integer(0,1023)},
        {"instrument_type", text}, {"transposition", integer(-48,48)}, {"staves", array(staff,1,2)}}, {"staves"});
    const auto master = record({{"time_signature", record({{"numerator", integer(1,64)}, {"denominator", rhythm}}, {"numerator", "denominator"})},
        {"key_signature", record({{"accidentals", integer(-7,7)}, {"major", flag}, {"native_label", text}})},
        {"repeat_start", flag}, {"repeat_end", flag}, {"repeat_count", integer(0,100)}, {"alternate_endings", array(integer(1,8),0,8)},
        {"directions", array(QJsonObject{{"anyOf", QJsonArray{integer(0,18),object}}},0,19)}, {"double_bar", flag}, {"free_time", flag},
        {"section", nullable(record({{"name", text}, {"text", text}}, {"name"}))}});
    QJsonObject page;
    for (const auto &field : pageFields()) page[field.name] = record({{"text", text}, {"visibility", integer(0,2)}});
    return record({{"schema", QJsonObject{{"const", "guitarpromcp.p8"}}}, {"version", QJsonObject{{"const", 1}}},
        {"metadata", QJsonObject{{"type", "object"}, {"additionalProperties", text}}}, {"page_metadata", record(page)},
        {"master_bars", array(master,1,256)}, {"tracks", array(track,1,32)},
        {"tempo_points", array(record({{"bar", integer(0,255)}, {"position", number}, {"value", integer(1,400)}, {"unit", text}, {"linear", flag}, {"label", text}, {"quarter_bpm", number}}, {"bar", "value"}),0,4096)}}, {"master_bars", "tracks"});
}
inline bool semanticParseSpec(const QJsonObject &args, QJsonObject *spec, QString *error) {
    auto value = args.value("spec");
    if (value.isString()) {
        QJsonParseError issue; const auto parsed = QJsonDocument::fromJson(value.toString().toUtf8(), &issue);
        if (issue.error != QJsonParseError::NoError || !parsed.isObject()) { *error = "spec must contain a JSON object"; return false; }
        value = parsed.object();
    }
    if (!value.isObject()) { *error = "spec must be an object or JSON object string"; return false; }
    *spec = value.toObject(); return true;
}
inline bool semanticValidateSpec(const QJsonObject &spec, QString *error) {
    try {
        semanticKeys(spec, {"schema", "version", "metadata", "page_metadata", "master_bars", "tempo_points", "tracks"});
        if (spec.contains("page_metadata")) semanticRequire(spec.value("page_metadata").isObject(), "page_metadata must be an object");
        if (spec.contains("schema") || spec.contains("version")) semanticRequire(spec.value("schema") == "guitarpromcp.p8" && spec.value("version") == 1, "Unsupported score schema/version");
        semanticRequire(spec.value("master_bars").isArray() && !spec.value("master_bars").toArray().isEmpty() && spec.value("master_bars").toArray().size() <= 256, "master_bars must contain 1..256 objects");
        const int bars = spec.value("master_bars").toArray().size();
        for (const auto value : spec.value("master_bars").toArray()) {
            semanticRequire(value.isObject(), "Master bar must be an object");
            semanticKeys(value.toObject(), {"time_signature", "key_signature", "repeat_start", "repeat_end", "repeat_count", "alternate_endings", "directions", "double_bar", "free_time", "section"});
        }
        if (spec.contains("metadata")) {
            semanticRequire(spec.value("metadata").isObject(), "metadata must be an object");
            const auto m = spec.value("metadata").toObject(); for (auto i = m.begin(); i != m.end(); ++i) semanticText(i.value());
        }
        if (spec.contains("tempo_points")) semanticRequire(spec.value("tempo_points").isArray() && spec.value("tempo_points").toArray().size() <= 4096, "Invalid tempo_points array");
        semanticRequire(spec.value("tracks").isArray() && !spec.value("tracks").toArray().isEmpty() && spec.value("tracks").toArray().size() <= 32, "tracks must contain 1..32 objects");
        int total = 0;
        for (const auto tv : spec.value("tracks").toArray()) {
            semanticRequire(tv.isObject(), "Track must be an object"); const auto track = tv.toObject();
            semanticKeys(track, {"name", "short_name", "template", "source_track", "instrument_type", "transposition", "staves"});
            for (const char *key : {"name", "short_name", "template", "instrument_type"}) if (track.contains(key)) semanticText(track.value(key), 256);
            if (track.contains("source_track")) semanticInt(track.value("source_track"), 0, 1023, "source_track");
            if (track.contains("transposition")) semanticInt(track.value("transposition"), -48, 48, "transposition");
            semanticRequire(track.value("staves").isArray() && track.value("staves").toArray().size() >= 1 && track.value("staves").toArray().size() <= 2, "Each track needs 1..2 staves");
            for (const auto sv : track.value("staves").toArray()) {
                semanticRequire(sv.isObject(), "Staff must be an object"); const auto staff = sv.toObject();
                semanticKeys(staff, {"tuning", "capo", "partial_capo", "partial_capo_strings", "bars"});
                if (staff.contains("tuning")) {
                    semanticRequire(staff.value("tuning").isArray() && staff.value("tuning").toArray().size() <= 12, "Invalid tuning array");
                    for (const auto p : staff.value("tuning").toArray()) semanticInt(p, 0, 127, "tuning pitch");
                }
                for (const char *key : {"capo", "partial_capo"}) if (staff.contains(key)) semanticInt(staff.value(key), 0, 24, key);
                semanticRequire(staff.value("bars").isArray() && staff.value("bars").toArray().size() == bars, "Every staff must have the master-bar count");
                for (const auto bv : staff.value("bars").toArray()) {
                    semanticRequire(bv.isObject(), "Bar must be an object"); const auto bar = bv.toObject(); semanticKeys(bar, {"voices"});
                    semanticRequire(bar.value("voices").isArray() && bar.value("voices").toArray().size() <= 4, "voices must be an array of at most four voices");
                    for (const auto vv : bar.value("voices").toArray()) {
                        semanticRequire(vv.isObject(), "Voice must be an object"); const auto voice = vv.toObject(); semanticKeys(voice, {"beats"});
                        semanticRequire(voice.value("beats").isArray(), "Voice needs a beats array (which may be empty)");
                        for (const auto beatValue : voice.value("beats").toArray()) {
                            semanticRequire(++total <= 20000 && beatValue.isObject(), "Specs may contain at most 20000 beat objects in total");
                            const auto beat = beatValue.toObject(); semanticKeys(beat, {"denominator", "dots", "tuplets", "rest", "notes", "effects", "text", "chord", "lyrics", "legato"});
                            const int denominator = semanticInt(semanticDefault(beat, "denominator", 4), 1, 128, "denominator"); semanticRequire(!(denominator & (denominator - 1)), "denominator must be a power of two");
                            semanticInt(semanticDefault(beat, "dots", 0), 0, 2, "dots");
                            if (beat.contains("rest")) semanticRequire(beat.value("rest").isBool(), "rest must be boolean");
                            if (beat.contains("text")) semanticText(beat.value("text"));
                            for (const char *key : {"effects", "tuplets", "legato"}) if (beat.contains(key)) semanticRequire(beat.value(key).isObject(), QString(key) + " must be an object");
                            if (beat.contains("chord")) semanticRequire(beat.value("chord").isNull() || beat.value("chord").isObject(), "chord must be null or an object");
                            if (beat.contains("lyrics")) semanticRequire(beat.value("lyrics").isArray() && beat.value("lyrics").toArray().size() <= 5, "lyrics supports five lines");
                            semanticRequire(!beat.contains("notes") || (beat.value("notes").isArray() && beat.value("notes").toArray().size() <= 32), "notes must be an array of at most 32 notes");
                            if (beat.contains("rest")) semanticRequire(beat.value("rest").toBool() == beat.value("notes").toArray().isEmpty(), "rest must agree with the notes array");
                            for (const auto nv : beat.value("notes").toArray()) {
                                semanticRequire(nv.isObject(), "Note must be an object"); const auto note = nv.toObject();
                                semanticKeys(note, {"string", "fret", "midi", "sounding_midi", "accidental", "tie", "effects"});
                                if (note.contains("midi")) semanticInt(note.value("midi"), 0, 127, "midi");
                                if (note.contains("string")) semanticInt(note.value("string"), 0, 127, "string");
                                if (note.contains("fret")) semanticInt(note.value("fret"), -1, 36, "fret");
                                for (const char *key : {"effects", "tie"}) if (note.contains(key)) semanticRequire(note.value(key).isObject(), QString(key) + " must be an object");
                            }
                        }
                    }
                }
            }
        }
        return true;
    } catch (const std::exception &e) { if (error) *error = QString::fromUtf8(e.what()); return false; }
}
inline void semanticMetadata(gp::core::Score *score, const QJsonObject &values) {
    const auto names = metadata(score);
    for (auto i = values.begin(); i != values.end(); ++i) {
        semanticRequire(names.contains(i.key()), "Unknown metadata property: " + i.key()); const auto text = semanticText(i.value());
        for (int p = 0; p <= 10; ++p) if (gp::core::scorePropertyToQString(static_cast<gp::core::ScoreProperty>(p)) == i.key()) score->setProperty(static_cast<gp::core::ScoreProperty>(p), text.toStdString());
    }
}
// Supplied fields are assertions about the resulting native model. Omitted
// fields retain native defaults; native-derived values cannot be silently lost.
inline void semanticMatch(const QJsonValue &wanted, const QJsonValue &actual, const QString &path = "spec") {
    if (wanted.isObject()) {
        semanticRequire(actual.isObject(), "Native readback type differs at " + path);
        const auto object = wanted.toObject();
        for (auto i = object.begin(); i != object.end(); ++i) {
            if (i.key() == "template" || i.key() == "source_track") continue;
            semanticMatch(i.value(), actual.toObject().value(i.key()), path + "." + i.key());
        }
    } else if (wanted.isArray()) {
        semanticRequire(actual.isArray(), "Native readback type differs at " + path);
        const auto w = wanted.toArray(), a = actual.toArray();
        const bool voices = path.endsWith(".voices");
        const bool fingers = path.endsWith(".fingers");
        semanticRequire(w.size() == a.size() || ((voices || fingers) && w.size() <= a.size()), "Native readback count differs at " + path);
        for (int i = 0; i < w.size(); ++i) {
            int found = i;
            if (path.endsWith(".notes")) {
                const auto note = w[i].toObject(); const auto key = note.contains("string") ? "string" : "midi"; found = -1;
                for (int n = 0; n < a.size(); ++n) if (a[n].toObject().value(key) == note.value(key)) { found = n; break; }
                semanticRequire(found >= 0, "Native note identity differs at " + path);
            }
            if (fingers) {
                found = -1;
                for (int n = 0; n < a.size(); ++n) if (a[n].toObject().value("string") == w[i].toObject().value("string") && a[n].toObject().value("fret") == w[i].toObject().value("fret")) { found = n; break; }
                semanticRequire(found >= 0, "Native finger position differs at " + path);
            }
            if (path.endsWith(".directions") && w[i].isDouble()) { semanticRequire(w[i] == a[i].toObject().value("id"), "Native direction differs at " + path); continue; }
            semanticMatch(w[i], a[found], path + "[" + QString::number(i) + "]");
        }
        if (voices) for (int i = w.size(); i < a.size(); ++i) semanticRequire(a[i].toObject().value("beats").toArray().isEmpty(), "Native omitted voice is not empty at " + path);
    } else semanticRequire(wanted == actual, "Native readback differs at " + path + ": expected " + QString::fromUtf8(QJsonDocument(QJsonArray{wanted}).toJson(QJsonDocument::Compact)) + ", got " + QString::fromUtf8(QJsonDocument(QJsonArray{actual}).toJson(QJsonDocument::Compact)));
}
inline void semanticEmptyVoice(gp::core::Score *score, int t, int s, int b, int v) {
    const auto staff = semanticStaff(score, t, s); const auto voice = static_cast<const gp::core::Bar &>(*staff->bars()[size_t(b)]).voices()[size_t(v)];
    if (!voice || voice->beats().empty()) return;
    gp::core::ScoreModelIndex first(score->modelPrivate().get(), t, b, 0, unsigned(s), unsigned(v));
    gp::core::ScoreModelIndex last(score->modelPrivate().get(), t, b, int(voice->beats().size()) - 1, unsigned(s), unsigned(v));
    gp::core::ScoreModelRange range(first, last, 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0)); range.setMultiSelection(true);
    score->removeBeatRange(range);
    for (const auto &beat : voice->beats()) semanticRequire(beat->isPlaceholder(), "Native voice clearing left real beats");
}
inline void semanticFillVoice(gp::core::Score *score, const QJsonArray &beats, int t, int s, int b, int v) {
    semanticEmptyVoice(score, t, s, b, v);
    const auto track = score->tracks()[size_t(t)]; const auto staff = semanticStaff(score, t, s);
    const bool stringed = gp::core::InstrumentSet::isStringed(track->type()), unpitched = track->instrumentSet().isUnpitched();
    for (int k = 0; k < beats.size(); ++k) {
        const auto input = beats[k].toObject(); const int denominator = semanticDefault(input, "denominator", 4).toInt(), dots = semanticDefault(input, "dots", 0).toInt();
        const int value = QList<int>{1,2,4,8,16,32,64,128}.indexOf(denominator) + 2;
        semanticMove(score, t, s, b, v, k);
        gp::core::ScoreModelRange range(score->cursor().modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
        const gp::core::RhythmValue rhythm(static_cast<gp::core::RhythmValue::Value>(value), dots, 0, 0); score->createBeat(range, rhythm);
        semanticMove(score, t, s, b, v, k);
        const auto current = score->cursor().beat(); semanticRequire(current && !current->isPlaceholder(), "Native beat creation failed");
        gp::core::ScoreModelRange written(score->cursor().modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0));
        QSet<int> positions;
        for (const auto nv : input.value("notes").toArray()) {
            const auto note = nv.toObject();
            if (stringed) {
                const int string = semanticInt(note.value("string"), 0, int(staff->tuning().stringCount()) - 1, "string"), fret = semanticInt(note.value("fret"), 0, 36, "fret");
                semanticRequire(!positions.contains(string) && staff->midi(unsigned(string), fret) >= 0 && staff->midi(unsigned(string), fret) <= 127, "Duplicate string or unplayable pitch"); positions.insert(string);
                const int accidental = note.contains("accidental") && !note.value("accidental").isNull() ? semanticInt(note.value("accidental"), -3, 2, "accidental") : -3;
                score->setStringedNote(written, true, string, fret, static_cast<am::music::Accidental>(accidental), current->rhythm());
            } else {
                const int midi = semanticInt(note.value("midi"), 0, 127, "midi"); semanticRequire(!positions.contains(midi), "Duplicate MIDI pitch"); positions.insert(midi);
                if (unpitched) {
                    const int index = track->instrumentSet().indexOfArticulationWithMidi(unsigned(midi)); const auto &articulations = track->instrumentSet().articulations();
                    semanticRequire(index >= 0 && size_t(index) < articulations.size(), "No native percussion articulation for MIDI pitch");
                    score->createNonPitchedNote(written, current->rhythm(), articulations[size_t(index)]);
                } else score->setMIDINote(written, unsigned(midi));
            }
        }
        const auto tuplets = input.value("tuplets").toObject(); semanticKeys(tuplets, {"primary", "secondary"});
        for (int level = 0; level < 2; ++level) {
            const auto tuplet = tuplets.value(level ? "secondary" : "primary").toObject();
            if (!tuplet.value("enabled").toBool()) continue;
            const int actual = semanticInt(tuplet.value("actual"), 1, 255, "tuplet.actual"), normal = semanticInt(tuplet.value("normal"), 1, 255, "tuplet.normal");
            score->setBeatTuplet(written, true, gp::core::TupletRatio{static_cast<unsigned char>(actual), static_cast<unsigned char>(normal)}, static_cast<gp::core::TupletLevel>(level));
        }
        if (input.contains("text")) score->setBeatFreeText(written, semanticText(input.value("text")).toStdString(), false);
        if (input.value("chord").isObject()) semanticSetChord(score, written, input.value("chord").toObject(), stringed ? int(staff->tuning().stringCount()) : 0);
    }
}
inline void semanticEffects(const Document &document, const QJsonArray &beats, int t, int s, int b, int v) {
    for (int k = 0; k < beats.size(); ++k) {
        semanticMove(document.score, t, s, b, v, k); const auto input = beats[k].toObject();
        auto effects = input.value("effects").toObject();
        for (auto e = effects.begin(); e != effects.end(); ++e) {
            if (beatEffects(*document.score->cursor().beat()).value(e.key()) == e.value()) continue;
            semanticResult(editBeatEffect({{"property", e.key()}, {"value", e.value()}}, document));
        }
        const auto notes = input.value("notes").toArray();
        const auto nativeIndex = [&](const QJsonObject &note) {
            const auto native = document.score->cursor().beat()->notes();
            const bool stringed = gp::core::InstrumentSet::isStringed(document.score->tracks()[size_t(t)]->type());
            for (int n = 0; n < int(native.size()); ++n) if (stringed ? int(native[size_t(n)]->string()) == note.value("string").toInt(-1) : native[size_t(n)]->midi() == note.value("midi").toInt(-1)) return n;
            throw std::runtime_error("Native note disappeared during effect construction");
        };
        for (int n = 0; n < notes.size(); ++n) {
            const int index = nativeIndex(notes[n].toObject());
            const auto effects = notes[n].toObject().value("effects").toObject();
            for (auto e = effects.begin(); e != effects.end(); ++e) {
                if (e.key() == "hopo_destination") continue;
                const auto nativeNotes = document.score->cursor().beat()->notes();
                if (noteState(*nativeNotes[size_t(index)]).value("effects").toObject().value(e.key()) == e.value()) continue;
                if (e.key() == "slide" && e.value().toObject().contains("flags")) {
                    const int flags = semanticInt(e.value().toObject().value("flags"), 0, (1 << slideKinds().size()) - 1, "slide.flags");
                    for (int f = 0; f < slideKinds().size(); ++f) if (flags & (1 << f)) semanticResult(editNoteEffect({{"note_index", index}, {"property", "slide"}, {"value", QJsonObject{{"kind", slideKinds()[f]}, {"enabled", true}}}}, document));
                } else semanticResult(editNoteEffect({{"note_index", index}, {"property", e.key()}, {"value", e.value()}}, document));
            }
        }
        if (input.value("legato").toObject().value("origin").toBool()) semanticResult(editConnection({{"kind", "legato"}, {"enabled", true}}, document));
        for (int n = 0; n < notes.size(); ++n) if (notes[n].toObject().value("tie").toObject().value("destination").toBool()) {
            semanticResult(editConnection({{"kind", "tie"}, {"enabled", true}, {"note_index", nativeIndex(notes[n].toObject())}}, document));
        }
    }
}
inline void semanticMaster(const Document &document, const QJsonObject &input, int bar) {
    semanticMove(document.score, 0, 0, bar, 0, 0);
    for (const char *key : {"time_signature", "key_signature"}) if (input.contains(key)) {
        semanticRequire(input.value(key).isObject(), QString(key) + " must be an object"); auto args = input.value(key).toObject(); args.remove("native_label"); args["operation"] = key; semanticResult(editMeasure(args, document));
    }
    for (const char *key : {"repeat_start", "repeat_end", "double_bar", "free_time"}) if (input.contains(key)) {
        QJsonObject args{{"operation", key}, {"enabled", input.value(key)}};
        if (QByteArray(key) == "repeat_end" && input.value(key).toBool()) args["repeat_count"] = semanticDefault(input, "repeat_count", 2);
        semanticResult(editMeasure(args, document));
    }
    if (input.contains("alternate_endings")) semanticResult(editMeasure({{"operation", "alternate_endings"}, {"endings", input.value("alternate_endings")}}, document));
    if (input.contains("directions")) {
        semanticRequire(input.value("directions").isArray() && input.value("directions").toArray().size() <= 19, "Invalid directions array");
        const auto existing = document.score->masterTrack()->directionsAtBarIndex(bar);
        for (const auto d : existing) semanticResult(editMeasure({{"operation", "direction"}, {"direction", int(d)}, {"enabled", false}}, document));
        for (const auto d : input.value("directions").toArray()) semanticResult(editMeasure({{"operation", "direction"}, {"direction", d.isObject() ? d.toObject().value("id") : d}, {"enabled", true}}, document));
    }
    if (input.contains("section")) {
        if (input.value("section").isNull()) {
            gp::core::ScoreModelRange range(document.score->cursor().modelIndex(), 0, static_cast<gp::core::ScoreModelRange::SortingPolicy>(0)); document.score->unsetMasterBarSection(range);
        } else {
            semanticRequire(input.value("section").isObject(), "section must be null or an object"); const auto section = input.value("section").toObject(); semanticKeys(section, {"name", "text"});
            document.score->setMasterBarSection(unsigned(bar), true, gp::core::MasterBar::Section{semanticText(section.value("name"), 256).toStdString(), semanticText(semanticDefault(section, "text", "")).toStdString()}, false);
        }
    }
}
inline std::shared_ptr<gp::core::Score> semanticBuild(const Document &document, const QJsonObject &spec, const QString &mode, int insertion) {
    auto score = semanticCopy(document.score); QObject object; const Document bound{nullptr, &object, score.get()};
    const auto tracks = spec.value("tracks").toArray(); const auto masters = spec.value("master_bars").toArray();
    int offset = 0;
    if (mode == "replace") {
        std::vector<std::shared_ptr<gp::core::Track>> prototypes;
        std::vector<std::shared_ptr<gp::core::Score>> templates;
        for (int t = 0; t < tracks.size(); ++t) {
            const auto input = tracks[t].toObject(); std::shared_ptr<gp::core::Track> prototype;
            const auto matches = [&](const std::shared_ptr<gp::core::Track> &track) { return track && (!input.contains("instrument_type") || input.value("instrument_type").toString() == QString::fromStdString(gp::core::InstrumentSet::typeToString(track->type()))) && int(track->staves().size()) == input.value("staves").toArray().size(); };
            const int source = input.value("source_track").toInt(t);
            if (!input.contains("template") && source >= 0 && size_t(source) < score->tracks().size() && matches(score->tracks()[size_t(source)])) prototype = score->tracks()[size_t(source)];
            if (!prototype) {
                const QDir directory(":/GPBase/MainWindow/Templates");
                QStringList names = input.contains("template") ? QStringList{input.value("template").toString() + ".gpt"} : directory.entryList({"*.gpt"}, QDir::Files, QDir::Name);
                for (const auto &name : names) {
                    semanticRequire(directory.entryList({"*.gpt"}, QDir::Files).contains(name), "Unknown built-in template");
                    const auto loaded = std::make_shared<gp::core::Score>(); loaded->load(directory.filePath(name)); templates.push_back(loaded);
                    const int index = input.value("source_track").toInt(0);
                    for (int i = 0; i < int(loaded->trackCount()); ++i) if ((!input.contains("template") || i == index) && matches(loaded->tracks()[size_t(i)])) { prototype = loaded->tracks()[size_t(i)]; break; }
                    if (prototype) break;
                }
            }
            semanticRequire(bool(prototype), "No compatible native track prototype; select a built-in template/source_track"); prototypes.push_back(prototype);
        }
        for (int t = int(score->trackCount()) - 1; t >= 0; --t) score->removeTrack(unsigned(t));
        for (int t = 0; t < tracks.size(); ++t) score->createTrack(unsigned(t), prototypes[size_t(t)], 4, true, false, false, 0);
        const int count = int(score->masterTrack()->masterBarCount());
        if (count < masters.size()) score->createBars(unsigned(count), unsigned(masters.size() - count));
        else if (count > masters.size()) score->removeBarRange(unsigned(masters.size()), unsigned(count - 1));
    } else {
        semanticRequire(mode == "append" || mode == "insert", "mode must be replace, append or insert");
        semanticRequire(tracks.size() == int(score->trackCount()), "Append/insert specs must match the existing track count");
        const auto original = semanticScore(document.score);
        if (spec.contains("metadata")) semanticMatch(spec.value("metadata"), original.value("metadata"), "metadata");
        if (spec.contains("page_metadata")) semanticMatch(spec.value("page_metadata"), original.value("page_metadata"), "page_metadata");
        for (int t = 0; t < tracks.size(); ++t) {
            auto properties = tracks[t].toObject(); properties.remove("staves");
            semanticRequire(!properties.contains("template") && !properties.contains("source_track"), "Append/insert cannot replace instruments");
            const auto originalTrack = original.value("tracks").toArray()[t].toObject(); semanticMatch(properties, originalTrack, "track");
            const auto staves = tracks[t].toObject().value("staves").toArray(), oldStaves = originalTrack.value("staves").toArray();
            semanticRequire(staves.size() == oldStaves.size(), "Append/insert staff count differs");
            for (int s = 0; s < staves.size(); ++s) { auto p = staves[s].toObject(); p.remove("bars"); semanticMatch(p, oldStaves[s], "staff"); }
        }
        offset = mode == "append" ? int(score->masterTrack()->masterBarCount()) : insertion;
        semanticRequire(offset >= 0 && offset <= int(score->masterTrack()->masterBarCount()) && score->masterTrack()->masterBarCount() + masters.size() <= 256, "Invalid insertion bar or result exceeds 256 bars");
        score->createBars(unsigned(offset), unsigned(masters.size()));
    }
    semanticMetadata(score.get(), spec.value("metadata").toObject());
    if (spec.contains("page_metadata")) setPageMetadata(score.get(), spec.value("page_metadata").toObject());
    for (int b = 0; b < masters.size(); ++b) semanticMaster(bound, masters[b].toObject(), offset + b);
    for (int t = 0; t < tracks.size(); ++t) {
        const auto input = tracks[t].toObject(); const auto base = trackBase(score.get(), unsigned(t));
        semanticRequire(bool(base) && score->tracks()[size_t(t)]->staves().size() == size_t(input.value("staves").toArray().size()), "Native staff count differs from spec");
        if (input.contains("name")) score->setTrackName(*base, input.value("name").toString().toStdString());
        if (input.contains("short_name")) score->setTrackShortName(*base, input.value("short_name").toString().toStdString());
        if (input.contains("transposition")) score->setTrackTranspositionOffset(*score->tracks()[size_t(t)], input.value("transposition").toInt());
        const auto staves = input.value("staves").toArray();
        for (int s = 0; s < staves.size(); ++s) {
            const auto staff = staves[s].toObject();
            if (gp::core::InstrumentSet::isStringed(score->tracks()[size_t(t)]->type())) {
                QJsonObject tuning{{"track", t}, {"staff", s}, {"preserve_pitch", false}};
                for (const char *key : {"tuning", "capo", "partial_capo", "partial_capo_strings"}) if (staff.contains(key)) tuning[key] = staff.value(key);
                semanticResult(editTuning(tuning, bound));
            } else for (const char *key : {"tuning", "capo", "partial_capo", "partial_capo_strings"}) semanticRequire(!staff.contains(key), "Tuning/capo requires a stringed instrument");
            const auto bars = staff.value("bars").toArray();
            for (int b = 0; b < bars.size(); ++b) {
                const auto voices = bars[b].toObject().value("voices").toArray();
                for (int v = 0; v < 4; ++v) semanticFillVoice(score.get(), v < voices.size() ? voices[v].toObject().value("beats").toArray() : QJsonArray(), t, s, offset + b, v);
            }
        }
    }
    for (int t = 0; t < tracks.size(); ++t) {
        const auto staves = tracks[t].toObject().value("staves").toArray();
        for (int s = 0; s < staves.size(); ++s) {
            const auto bars = staves[s].toObject().value("bars").toArray();
            for (int b = 0; b < bars.size(); ++b) {
                const auto voices = bars[b].toObject().value("voices").toArray();
                for (int v = 0; v < voices.size(); ++v) semanticEffects(bound, voices[v].toObject().value("beats").toArray(), t, s, offset + b, v);
            }
        }
    }
    if (spec.contains("tempo_points")) {
        if (mode == "replace") {
            std::vector<std::shared_ptr<gp::core::Automation>> points;
            score->masterTrack()->gp::core::AutomationContainerProxy::getAutomations(static_cast<gp::core::Automation::Type>(0x200), points);
            semanticRequire(!points.empty(), "Native initial tempo is missing");
            auto initial = static_cast<gp::core::TempoAutomation *>(points.front().get())->gp::core::TempoAutomation::cloneAutomation();
            initial->gp::core::Automation::setBarIndex(0); initial->setPosition(0);
            score->modifyMasterTrackAutomations({initial}, {});
        }
        QSet<QString> positions;
        for (const auto point : spec.value("tempo_points").toArray()) {
            semanticRequire(point.isObject(), "Tempo point must be an object"); auto args = point.toObject();
            semanticKeys(args, {"bar", "position", "value", "unit", "linear", "label", "quarter_bpm"}); args.remove("quarter_bpm");
            const int bar = semanticInt(args.value("bar"), 0, masters.size() - 1, "tempo bar"); args["bar"] = offset + bar; args["operation"] = "set";
            const QString key = QString::number(bar) + ":" + QString::number(args.value("position").toDouble(), 'g', 9); semanticRequire(!positions.contains(key), "Duplicate tempo point"); positions.insert(key);
            semanticResult(tempoAutomation(args, bound));
        }
    }
    // Native commands can rebuild beats. Set literal fragments on the final
    // isolated beat objects, after all commands and before the single commit.
    for (int t = 0; t < tracks.size(); ++t) {
        const auto staves = tracks[t].toObject().value("staves").toArray();
        for (int s = 0; s < staves.size(); ++s) {
            const auto bars = staves[s].toObject().value("bars").toArray();
            for (int b = 0; b < bars.size(); ++b) {
                const auto voices = bars[b].toObject().value("voices").toArray();
                for (int v = 0; v < voices.size(); ++v) {
                    const auto beats = voices[v].toObject().value("beats").toArray();
                    for (int k = 0; k < beats.size(); ++k) {
                        semanticMove(score.get(), t, s, offset + b, v, k); const auto beat = score->cursor().beat();
                        for (unsigned line = 0; line < 5; ++line) beat->setLyrics({}, line);
                        QSet<int> lines;
                        for (const auto lv : beats[k].toObject().value("lyrics").toArray()) {
                            const auto lyric = lv.toObject(); semanticKeys(lyric, {"line", "text"}); const int line = semanticInt(lyric.value("line"), 0, 4, "lyric.line");
                            semanticRequire(!lines.contains(line), "Duplicate lyric line"); lines.insert(line); beat->setLyrics(semanticText(lyric.value("text")).toStdString(), unsigned(line));
                        }
                    }
                }
            }
        }
    }
    auto actual = semanticScore(score.get());
    if (mode != "replace") {
        QJsonArray barSlice, trackSlice, tempos;
        for (int b = 0; b < masters.size(); ++b) barSlice.append(actual.value("master_bars").toArray()[offset + b]);
        actual["master_bars"] = barSlice;
        for (const auto tv : actual.value("tracks").toArray()) {
            auto track = tv.toObject(); QJsonArray staves;
            for (const auto sv : track.value("staves").toArray()) {
                auto staff = sv.toObject(); QJsonArray bars;
                for (int b = 0; b < masters.size(); ++b) bars.append(staff.value("bars").toArray()[offset + b]);
                staff["bars"] = bars; staves.append(staff);
            }
            track["staves"] = staves; trackSlice.append(track);
        }
        actual["tracks"] = trackSlice;
        for (const auto pv : actual.value("tempo_points").toArray()) {
            auto point = pv.toObject(); const int b = point.value("bar").toInt() - offset;
            if (b >= 0 && b < masters.size()) { point["bar"] = b; tempos.append(point); }
        }
        actual["tempo_points"] = tempos;
    }
    semanticMatch(spec, actual);
    return score;
}
inline QJsonObject applySpec(const QJsonObject &args, std::function<QJsonObject()> &recovery) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    QJsonObject spec; QString error; semanticRequire(semanticParseSpec(args, &spec, &error) && semanticValidateSpec(spec, &error), error);
    const QString mode = args.value("mode").toString("replace");
    const auto staged = semanticBuild(document, spec, mode, args.value("bar").toInt(-1));
    auto result = semanticCommit(document, staged, recovery, qEnvironmentVariableIsSet("GPMCP_DEVELOPMENT") ? args.value("debug_fault").toString() : QString()); result["mode"] = mode; return result;
}
inline QJsonObject insertTab(const QJsonObject &args, std::function<QJsonObject()> &recovery) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    const QString text = semanticText(args.value("text"), 32000), mode = args.value("mode").toString("append");
    const int t = semanticInt(semanticDefault(args, "track", 0), 0, int(document.score->trackCount()) - 1, "track"), s = semanticInt(semanticDefault(args, "staff", 0), 0, 1, "staff"), v = semanticInt(semanticDefault(args, "voice", 0), 0, 3, "voice");
    const auto staff = semanticStaff(document.score, t, s); semanticRequire(gp::core::InstrumentSet::isStringed(document.score->tracks()[size_t(t)]->type()), "Text riff requires a stringed track");
    const int string = semanticInt(semanticDefault(args, "string", 0), 0, int(staff->tuning().stringCount()) - 1, "string"), denominator = semanticInt(semanticDefault(args, "denominator", 8), 1, 128, "denominator");
    semanticRequire(!(denominator & (denominator - 1)), "denominator must be a power of two");
    const auto parts = text.split('|'); semanticRequire(parts.size() >= 1 && parts.size() <= 128, "Text riff supports 1..128 bars"); QJsonArray bars;
    for (const auto &part : parts) {
        semanticRequire(QRegularExpression("^\\s*(?:[0-9]{1,2}|r)(?:[-\\s,]+(?:[0-9]{1,2}|r))*\\s*$").match(part).hasMatch(), "Riff contains an invalid fret/rest token");
        const auto tokens = part.trimmed().split(QRegularExpression("[-\\s,]+"), Qt::SkipEmptyParts); semanticRequire(!tokens.isEmpty() && tokens.size() <= 128, "Each riff bar needs 1..128 frets or r rests"); QJsonArray beats;
        for (const auto &token : tokens) {
            QJsonArray notes;
            if (token != "r") { bool ok = false; const int fret = token.toInt(&ok); semanticRequire(ok && fret >= 0 && fret <= 36, "Riff tokens must be frets 0..36 or r"); notes.append(QJsonObject{{"string", string}, {"fret", fret}}); }
            beats.append(QJsonObject{{"denominator", denominator}, {"notes", notes}});
        }
        bars.append(beats);
    }
    const auto staged = semanticCopy(document.score); int offset = mode == "append" ? int(staged->masterTrack()->masterBarCount()) : semanticInt(args.value("bar"), 0, int(staged->masterTrack()->masterBarCount()), "bar");
    semanticRequire(mode == "replace" || mode == "append" || mode == "insert", "mode must be replace, append or insert");
    if (mode == "replace") semanticRequire(offset + bars.size() <= int(staged->masterTrack()->masterBarCount()), "Replacement riff range must exist");
    else { semanticRequire(staged->masterTrack()->masterBarCount() + bars.size() <= 256, "Result exceeds 256 bars"); staged->createBars(unsigned(offset), unsigned(bars.size())); }
    for (int b = 0; b < bars.size(); ++b) semanticFillVoice(staged.get(), bars[b].toArray(), t, s, offset + b, v);
    return semanticCommit(document, staged, recovery);
}
inline QJsonObject exportTab(const QJsonObject &args) {
    const auto document = choose(args); semanticRequire(document.score, "Native document required");
    const int t = semanticInt(semanticDefault(args, "track", 0), 0, int(document.score->trackCount()) - 1, "track"), s = semanticInt(semanticDefault(args, "staff", 0), 0, 1, "staff");
    const auto staff = semanticStaff(document.score, t, s); semanticRequire(gp::core::InstrumentSet::isStringed(document.score->tracks()[size_t(t)]->type()), "ASCII tab requires a stringed track");
    const int from = semanticInt(semanticDefault(args, "bar", 0), 0, int(staff->bars().size()) - 1, "bar"), count = semanticInt(semanticDefault(args, "count", qMin(16, int(staff->bars().size()) - from)), 1, qMin(128, int(staff->bars().size()) - from), "count");
    const int voice = args.contains("voice") ? semanticInt(args.value("voice"), 0, 3, "voice") : -1;
    QString text; QTextStream out(&text); QJsonArray result; int inspected = 0;
    out << "track " << t << " staff " << s << " (MIDI tuning, highest string first; one column per beat)\n"
        << "capo " << staff->capoFret() << "; partial capo " << staff->partialCapoFret() << "; flags ";
    for (bool flag : staff->partialCapoStringFlags()) out << (flag ? '1' : '0');
    out << "\n";
    for (int b = from; b < from + count; ++b) {
        const auto &voices = static_cast<const gp::core::Bar &>(*staff->bars()[size_t(b)]).voices();
        for (int v = 0; v < int(voices.size()); ++v) if (voices[size_t(v)] && (voice < 0 || voice == v)) {
            QJsonArray beats; QString rhythm = "dur|"; QStringList lines;
            for (int pitch : staff->tuning().midiNumbers()) lines.append(QString::number(pitch).rightJustified(3) + "|");
            for (const auto &beat : voices[size_t(v)]->beats()) {
                semanticRequire(++inspected <= 20000, "ASCII read exceeds 20000 beats"); if (beat->isPlaceholder()) continue;
                const auto value = semanticBeat(*beat, *staff); beats.append(value);
                const QString duration = "1/" + QString::number(value.value("denominator").toInt()) + QString(value.value("dots").toInt(), '.'); const int width = qMax(6, duration.size() + 1);
                rhythm += duration.leftJustified(width);
                QStringList cells; for (int i = 0; i < lines.size(); ++i) cells.append(beat->isRest() ? "r" : "-");
                for (const auto &note : beat->notes()) { semanticRequire(note->string() < unsigned(cells.size()), "Native note string exceeds tuning"); cells[int(note->string())] = note->isDead() ? "x" : QString::number(note->fret()); }
                for (int i = 0; i < lines.size(); ++i) lines[i] += cells[i].leftJustified(width, '-');
            }
            out << "bar " << b << " voice " << v << "\n" << rhythm << "|\n";
            for (int i = lines.size() - 1; i >= 0; --i) out << lines[i] << "|\n";
            result.append(QJsonObject{{"bar", b}, {"voice", v}, {"beats", beats}});
        }
    }
    return {{"document", document.id()}, {"text", text}, {"bars", result}, {"reversible", false},
        {"unrepresented", QJsonArray{"tuplets", "ties and legato", "note and beat effects except dead notes", "chord symbols and lyrics", "engraving"}}};
}
}
