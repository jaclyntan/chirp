import SwiftUI

// MARK: - Legal
//
// Chirp itself is open-source under the MIT license. Four of its
// components are also open-source dependencies whose licenses require
// their text (MIT, Apache-2.0) or their text plus copyright notice
// (SIL OFL) to be reproduced somewhere in the shipped product. This is
// that somewhere.
//
// Full texts are fetched verbatim from each project's own LICENSE file
// rather than paraphrased, and the closing `"""` on each is left at column
// zero on purpose — indenting it to match the surrounding code would make
// Swift strip that much leading whitespace from every line, corrupting the
// license text's own internal indentation (Apache-2.0 in particular nests
// several levels deep).

struct LegalPage: View {
    var body: some View {
        GlassPanelPage {
            // `ThinScrollView`, not a plain `ScrollView` — see
            // ThinScrollView's own doc comment (DesignSystem.swift) for why: a bare
            // `.scrollIndicators(.hidden)` doesn't reliably suppress
            // macOS's native scroller by itself.
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    Text("Open-source components")
                        .font(.manrope(13, .semibold))
                        .foregroundStyle(Palette.warmInk)
                        .padding(.top, 18)

                    VStack(spacing: 0) {
                        ForEach(Array(OpenSourceComponent.all.enumerated()), id: \.offset) { index, component in
                            LicenseItem(component: component)
                            if index != OpenSourceComponent.all.count - 1 {
                                Rectangle().fill(Palette.warmRowBorder).frame(height: 1)
                            }
                        }
                    }
                    .padding(.top, 6)

                    tipBanner
                        .padding(.top, 18)
                }
                // The mockup caps this page's content at 760px rather
                // than letting it span the full glass panel — long
                // license text reads better in a narrower column.
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        // Applied once, here, rather than per `DisclosureGroup` — see
        // HelpView.swift's own twin of this style for why: macOS's
        // default indicator sits on the *leading* edge, ahead of the
        // component name, instead of trailing after the summary like
        // the mockup.
        .disclosureGroupStyle(TrailingCaretDisclosureStyle())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legal")
                .font(.chirpDisplay(23, .regular))
                .foregroundStyle(Palette.warmInk)
            Text("Chirp is open-source under the MIT license, and built with the help "
                 + "of a few other open-source projects. Their licenses are reproduced "
                 + "here in full, as each requires.")
                .font(.manrope(12.5))
                .foregroundStyle(Palette.warmInkFaint)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tipBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            ChirpIconView(icon: .help)
                .frame(width: 13, height: 13)
                .foregroundStyle(Palette.warmInkSoft)
                .padding(.top, 1)
            Text("Chirp's own source is on GitHub under the MIT license. The licenses "
                 + "above cover the third-party components listed, each used under "
                 + "terms that permit open-source redistribution.")
                .font(.manrope(12.5))
                .lineSpacing(3)
                .foregroundStyle(Palette.warmInkSoft)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chirpSurface()
    }
}

private struct LicenseItem: View {
    let component: OpenSourceComponent
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(component.copyright)
                    .font(.manrope(11.5, .medium))
                    .foregroundStyle(Palette.warmInkSoft)
                ThinScrollView {
                    Text(component.fullText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.warmInkSoft)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Palette.warmRowBorder, lineWidth: 1))
            }
            .padding(.top, 4)
            .padding(.bottom, 16)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(component.name)
                        .font(.manrope(13.5, .semibold))
                        .foregroundStyle(Palette.warmInk)
                    Text(component.license)
                        .font(.manrope(11))
                        .foregroundStyle(Palette.warmInkSoft)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Palette.warmRowBorder, in: Capsule())
                        .overlay(Capsule().stroke(Palette.warmDivider, lineWidth: 1))
                }
                Text(component.purpose)
                    .font(.manrope(12))
                    .foregroundStyle(Palette.warmInkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}

/// Moves `DisclosureGroup`'s indicator to the trailing edge of its label,
/// matching the mockup's own summary layout (name, chip, then the
/// chevron) — see HelpView.swift's own twin of this for the fuller note;
/// kept as a separate copy here since `private` there scopes it to that
/// file.
private struct TrailingCaretDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.chirpEase(0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    configuration.label
                    Spacer(minLength: 8)
                    ChirpIconView(icon: .caret)
                        .frame(width: 9, height: 9)
                        .foregroundStyle(Palette.warmInkFainter)
                        .padding(.top, 4)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct OpenSourceComponent {
    let name: String
    let purpose: String
    let license: String
    let copyright: String
    let fullText: String

    static let all: [OpenSourceComponent] = [
        OpenSourceComponent(
            name: "FluidAudio",
            purpose: "Voice-activity detection and end-of-turn detection behind every "
                + "dictation, and Notetaker's own meeting transcription — independent "
                + "of which speech-recognition engine is selected. (Also used to run "
                + "an optional Parakeet recognition engine; retired for now, see "
                + "docs/removed-engines.md.)",
            license: "Apache-2.0",
            copyright: "Copyright 2025 FluidInference",
            fullText: apacheLicense),
        OpenSourceComponent(
            name: "Harper",
            purpose: "The fast, deterministic grammar and style checker that cleans "
                + "up every non-Raw dictation — no AI rewrite pass runs by default; "
                + "this and Apple's own speech recognition are the whole pipeline.",
            license: "Apache-2.0",
            copyright: "Copyright 2024 Elijah Potter",
            fullText: apacheLicense),
        OpenSourceComponent(
            name: "Manrope",
            purpose: "The typeface used throughout Chirp's interface.",
            license: "SIL OFL 1.1",
            copyright: "Copyright 2018 The Manrope Project Authors "
                + "(https://github.com/sharanda/manrope)",
            fullText: manropeOFL),
        OpenSourceComponent(
            name: "Phosphor Icons",
            purpose: "Every icon throughout Chirp's interface — not linked in as a "
                + "package (Phosphor ships no Swift target), so each icon's path data "
                + "is reproduced directly in ChirpIcons.swift instead.",
            license: "MIT",
            copyright: "Copyright (c) 2023 Phosphor Icons",
            fullText: mitLicense(copyright: "Copyright (c) 2023 Phosphor Icons")),
    ]
}

/// Shared MIT template — components only differ by copyright line.
private func mitLicense(copyright: String) -> String {
    """
\(copyright)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
}

private let apacheLicense = """
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2024 Elijah Potter

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
"""

private let manropeOFL = """
Copyright 2018 The Manrope Project Authors (https://github.com/sharanda/manrope)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
"""
