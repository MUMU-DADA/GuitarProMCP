#pragma once
#include "guitarpro_audio.h"

namespace guitarpro {
struct PageField {
    const char *name;
    am::painting::FormattedText (*read)(const gp::core::style::Stylesheet &);
    gp::core::view::Visibility (*visible)(const gp::core::style::Stylesheet &);
    void (*write)(gp::core::style::Stylesheet &, const std::optional<am::painting::FormattedText> &);
    void (*show)(gp::core::style::Stylesheet &, const std::optional<gp::core::view::Visibility> &);
};
inline const std::vector<PageField> &pageFields() {
    using namespace gp::core::style;
#define FIELD(Key, Name, Setter) {Key, Name##FormattedTextValue, Name##VisibilityValue, Setter##FormattedText, Setter##Visibility}
    static const std::vector<PageField> fields{
        FIELD("even_header", scoreEvenPageHeaderField, setScoreEvenPageHeaderField),
        FIELD("odd_header", scoreOddPageHeaderField, setScoreOddPageHeaderField),
        FIELD("first_footer", scoreFirstPageFooterCopyright2, setScoreFirstPageFooterCopyright2),
        FIELD("even_footer", scoreEvenPageFooterCopyright2, setScoreEvenPageFooterCopyright2),
        FIELD("odd_footer", scoreOddPageFooterCopyright2, setScoreOddPageFooterCopyright2),
        FIELD("first_page_number", scoreFirstPageFooterPageNumber, setScoreFirstPageFooterPageNumber),
        FIELD("even_page_number", scoreEvenPageFooterPageNumber, setScoreEvenPageFooterPageNumber),
        FIELD("odd_page_number", scoreOddPageFooterPageNumber, setScoreOddPageFooterPageNumber)};
#undef FIELD
    return fields;
}
inline QJsonObject pageMetadata(gp::core::Score *score) {
    static const bool verified = supportedBuild() && verifiedHostFile("AMPainting.dll");
    if (!verified || !score->newStylesheet()) throw std::runtime_error("Page metadata requires the verified AMPainting build and stylesheet");
    QJsonObject result;
    for (const auto &field : pageFields()) result[field.name] = QJsonObject{
        {"text", QString::fromStdString(field.read(*score->newStylesheet()).text())}, {"visibility", int(field.visible(*score->newStylesheet()))}};
    const auto meta = metadata(score);
    for (const auto &pair : QList<QPair<QString, QString>>{{"title", "Title"}, {"author", "Artist"}, {"composer", "Music"}, {"copyright", "Copyright"}}) result[pair.first] = meta.value(pair.second);
    return result;
}
inline void setPageMetadata(gp::core::Score *score, const QJsonObject &input) {
    const auto before = pageMetadata(score);
    // Validate the entire group before changing even the isolated native copy.
    for (auto i = input.begin(); i != input.end(); ++i) {
        if (!before.contains(i.key())) throw std::runtime_error("Unknown page_metadata field");
        if (before.value(i.key()).isString()) {
            if (!i.value().isString() || i.value().toString().size() > 4096 || !validHostText(i.value().toString())) throw std::runtime_error("Invalid page metadata text");
        } else {
            if (!i.value().isObject()) throw std::runtime_error("Page fields require an object with text and/or visibility");
            const auto value = i.value().toObject();
            for (auto p = value.begin(); p != value.end(); ++p) {
                if (p.key() == "text" && p.value().isString() && p.value().toString().size() <= 4096 && validHostText(p.value().toString())) continue;
                if (p.key() == "visibility" && p.value().isDouble() && (p.value() == 0 || p.value() == 1 || p.value() == 2)) continue;
                throw std::runtime_error("Page field text must be valid text; visibility is 0=visible, 1=hidden, 2=collapsed");
            }
        }
    }
    for (const auto &pair : QList<QPair<QString, QString>>{{"title", "Title"}, {"author", "Artist"}, {"composer", "Music"}, {"copyright", "Copyright"}})
        if (input.contains(pair.first)) for (int p = 0; p <= 10; ++p) if (gp::core::scorePropertyToQString(static_cast<gp::core::ScoreProperty>(p)) == pair.second)
            score->setProperty(static_cast<gp::core::ScoreProperty>(p), input.value(pair.first).toString().toStdString());
    for (const auto &field : pageFields()) if (input.contains(field.name)) {
        const auto value = input.value(field.name).toObject();
        if (value.contains("text")) { auto text = field.read(*score->newStylesheet()); text.setText(value.value("text").toString().toStdString()); field.write(*score->newStylesheet(), text); }
        if (value.contains("visibility")) field.show(*score->newStylesheet(), static_cast<gp::core::view::Visibility>(value.value("visibility").toInt()));
    }
}
}
