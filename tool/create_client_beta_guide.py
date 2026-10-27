"""Generate the standalone French guide; never bundled into the employee APK.

Requires reportlab. Render the resulting two pages and visually review before sharing.
"""
import argparse
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, KeepTogether


TEAL = colors.HexColor('#126E82')
INK = colors.HexColor('#18323C')
MUTED = colors.HexColor('#506672')


def create(output: Path, font_dir: Path):
    pdfmetrics.registerFont(TTFont('Guide', str(font_dir / 'arial.ttf')))
    pdfmetrics.registerFont(TTFont('GuideBold', str(font_dir / 'arialbd.ttf')))
    pdfmetrics.registerFontFamily('Guide', normal='Guide', bold='GuideBold')
    body = ParagraphStyle('Body', fontName='Guide', fontSize=10.2, leading=14.2,
                          textColor=INK, spaceAfter=7, alignment=TA_LEFT)
    title = ParagraphStyle('Title', parent=body, fontName='GuideBold', fontSize=24,
                           leading=29, textColor=TEAL, spaceAfter=10)
    heading = ParagraphStyle('Heading', parent=body, fontName='GuideBold', fontSize=12,
                             leading=16, spaceBefore=10, spaceAfter=5)
    intro = ParagraphStyle('Intro', parent=body, fontSize=11, leading=15, textColor=MUTED)
    note = ParagraphStyle('Note', parent=body, fontSize=9.5, leading=13,
                          backColor=colors.HexColor('#EDF5F7'), borderPadding=10,
                          spaceBefore=7, spaceAfter=12)
    small = ParagraphStyle('Small', parent=body, fontSize=8, leading=11, textColor=MUTED)
    story = []

    def p(text, style=body):
        story.append(Paragraph(text, style))

    def section(label, text):
        story.append(KeepTogether([Paragraph(label, heading), Paragraph(text, body)]))

    def page(canvas, doc):
        canvas.setFillColor(TEAL)
        canvas.rect(0, A4[1] - 53, A4[0], 53, stroke=0, fill=1)
        canvas.setFillColor(colors.white)
        canvas.setFont('GuideBold', 16)
        canvas.drawString(42, A4[1] - 34, 'ChantiPoint')
        canvas.setFont('Guide', 9)
        canvas.drawRightString(A4[0] - 42, A4[1] - 32, 'BÊTA EMPLOYÉ  /  ANDROID')
        canvas.setFillColor(MUTED)
        canvas.setFont('Guide', 8)
        canvas.drawString(42, 26, 'Guide de test - 25 octobre 2026')
        canvas.drawRightString(A4[0] - 42, 26, f'{doc.page} / 2')

    p('Installer et activer', title)
    p('Une activation unique, puis l’application employé au quotidien.', intro)
    p('<b>Version de test.</b> Les pointages, notes et données GPS peuvent être '
      'enregistrés dans la base de développement. Utilisez uniquement le compte de test '
      'communiqué par le développeur.', note)
    section('1. Recevoir les fichiers et le compte',
      'Attendez la confirmation de votre compte. Le développeur fournit deux fichiers : '
      '<b>ChantiPoint-activation-universal.apk</b> (outil temporaire) et '
      '<b>ChantiPoint-beta-universal.apk</b> (application employé). '
      'Android 7.0 minimum ; la compatibilité de votre modèle Samsung reste à confirmer.')
    section('2. Installer l’outil temporaire',
      'Ouvrez le fichier d’activation reçu du développeur. Si Android le demande, '
      'autorisez cette source pour cette installation. Si Samsung ou une règle de votre '
      'entreprise bloque le fichier, contactez le développeur. Si ChantiPoint est déjà '
      'présent sur ce téléphone, signalez-le avant toute désinstallation ou réinitialisation.')
    section('3. Transmettre la demande d’activation',
      'Ouvrez <b>Activation ChantiPoint</b> et connectez-vous. Touchez '
      '<b>Préparer la demande</b>, puis <b>Enregistrer la demande</b>. '
      'Transmettez ce fichier au développeur par le canal privé convenu. '
      'Cette demande n’active pas encore le pointage.')
    section('4. Installer l’approbation, puis l’application',
      'Après vérification, le développeur vous renvoie un fichier d’activation. Dans '
      'l’outil, touchez <b>Choisir le fichier d’activation</b>, puis '
      '<b>Installer l’activation</b>. Attendez la confirmation. Ouvrez ensuite '
      '<b>ChantiPoint-beta-universal.apk</b> et acceptez la mise à jour. '
      '<b>Ne désinstallez pas l’outil entre ces deux étapes.</b> L’activation doit être conservée.')
    section('5. Préparer la localisation',
      'Activez la localisation du téléphone. Dans ChantiPoint, autorisez l’accès '
      '<b>lorsque vous utilisez l’application</b> et choisissez la <b>position précise</b> '
      'si ce choix est proposé. Après activation ou redémarrage, si '
      '<b>Réessayer la vérification sur cet appareil</b> apparaît, touchez ce bouton avant de pointer.')

    story.append(PageBreak())
    p('Tester une session', title)
    p('Répétez le parcours à différents endroits avec des descriptions de lieu utiles.', intro)
    section('Entrer et vérifier',
      'Saisissez une <b>Description du lieu</b> si nécessaire, puis touchez '
      '<b>Pointer une entrée</b>. Attendez la confirmation et vérifiez que la '
      '<b>Session active</b> apparaît. Si <b>Terminer la vérification</b> est proposé, '
      'touchez-le pour poursuivre. Ne créez pas une nouvelle entrée pour remplacer un résultat incertain.')
    section('Enregistrer, modifier ou supprimer une note',
      'Dans <b>Note pendant la session</b>, saisissez votre texte et touchez '
      '<b>Enregistrer la note</b>. Vérifiez la valeur enregistrée. Modifiez le texte '
      'et enregistrez à nouveau. Pour supprimer la note, utilisez '
      '<b>Effacer la note enregistrée</b>. Un brouillon seul n’est pas enregistré.')
    section('Sortir en conservant la bonne note',
      'Choisissez <b>Conserver la note enregistrée</b>, <b>Remplacer la note à la sortie</b> '
      'ou <b>Effacer la note à la sortie</b>, puis touchez <b>Pointer une sortie</b>. '
      'Attendez la confirmation et terminez la vérification si elle est proposée. '
      'Vérifiez qu’aucune session ne reste active.')
    section('Consulter votre historique personnel',
      'Touchez <b>Historique</b>, puis une session pour ouvrir ses détails : entrée, '
      'sortie, lieu, description, note et révision. Les heures sont affichées selon '
      '<b>Montréal</b>. La liste couvre les six derniers mois ; <b>Charger plus</b> '
      'affiche la suite lorsqu’elle existe. Utilisez <b>Accueil</b> pour revenir au pointage.')
    p('<b>Que signifie « À examiner » ?</b><br/>Le pointage est enregistré, mais un élément '
      'doit être vérifié, par exemple une précision GPS insuffisante. Une localisation '
      'non vérifiée ne signifie pas que la session a disparu.', note)
    section('Terminer le test et signaler un problème',
      'Fermez puis rouvrez l’application et vérifiez l’historique. Testez aussi la '
      'déconnexion normale. Pour signaler un problème, transmettez au développeur '
      'le modèle Samsung, la version Android, la date et l’heure, l’action tentée et '
      'le message affiché. Une capture d’écran peut aider ; ne transmettez pas votre mot de passe. '
      'Si le résultat reste incertain, contactez-le avant de réinstaller ou d’effacer des données.')
    story.append(Spacer(1, 7))
    p('Aide officielle : <link href="https://www.samsung.com/us/support/answer/ANS10003636/" '
      'color="#126E82">installation et protections Samsung</link>. '
      'Les intitulés Android peuvent varier selon le modèle.', small)
    output.parent.mkdir(parents=True, exist_ok=True)
    doc = SimpleDocTemplate(str(output), pagesize=A4, leftMargin=42, rightMargin=42,
        topMargin=73, bottomMargin=43, title='ChantiPoint - Guide de test bêta employé',
        author='ChantiPoint', pageCompression=1)
    doc.build(story, onFirstPage=page, onLaterPages=page)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('output/pdf/ChantiPoint-guide-beta-fr.pdf'))
    parser.add_argument('--font-dir', type=Path, default=Path('C:/Windows/Fonts'))
    args = parser.parse_args()
    create(args.output, args.font_dir)
