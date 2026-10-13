# Questions client - ChantiPoint v0.1

Ce document interne sert à préparer une discussion de validation. Il ne constitue pas une approbation du client et ne doit pas être envoyé tel quel.

## Points compris comme établis pour la planification

Ces points sont traités comme des exigences rapportées pour la planification, mais ils devront être confirmés dans une spécification approuvée.

1. L'application ChantiPoint doit être en français.
2. Le pilote vise d'abord Android; iOS demeure une cible future.
3. L'application doit enregistrer les pointages manuels d'entrée et de sortie.
4. Au pointage d'entrée, l'employé doit choisir entre `À l'usine` et `Chantier extérieur`.
5. Les sessions à l'usine enregistrent les heures d'entrée et de sortie sans GPS, sans géorepérage et sans permission de localisation.
6. Les sessions sur chantier extérieur peuvent enregistrer une position GPS au pointage d'entrée et utiliser une vérification par localisation si elle est validée et autorisée.
7. La localisation sert à fournir des indices liés au téléphone, sans prétendre prouver la présence physique ou la productivité de l'employé.
8. La paie est exclue de la V1; les totaux d'heures travaillées par mois et l'export CSV opérationnel sont requis.
9. Les rapports quotidiens et hebdomadaires sont des améliorations possibles, pas des livrables V1 confirmés.
10. Un administrateur désigné examine initialement les sessions, anomalies, fermetures automatiques proposées et demandes de correction.
11. Des administrateurs additionnels pourront être ajoutés plus tard, sans obliger une gestion complexe dès la V1.
12. L'employeur est responsable de l'avis aux employés, de la politique de surveillance, de l'EFVP et des validations légales ou RH.
13. Pour les corrections de pointage, l'employé peut fournir une explication simple; l'administrateur désigné exerce le jugement et prend la décision.
14. Le géorepérage demeure le candidat technique privilégié pour les chantiers extérieurs, sous réserve de faisabilité.
15. Les paramètres proposés sont un rayon de 100 à 150 m et un délai de grâce de 10 minutes après la réception fiable d'un événement de sortie.
16. Après 8 heures de session active, l'employé doit recevoir une notification avec `Terminer la session` et `Continuer la session`.
17. Ces décisions sont rapportées par le développeur après discussion client; elles ne constituent pas encore une approbation écrite formelle.

## Décisions encore ouvertes

1. Confirmez-vous formellement que le modèle de surveillance proposé pour les chantiers extérieurs est acceptable pour la V1?
2. Souhaitez-vous autoriser une fermeture automatique de session si le téléphone semble quitter le chantier au-delà du délai de grâce? Si oui, quelles exceptions doivent empêcher cette fermeture automatique?
3. Le rayon final doit-il être 100 m, 150 m ou une autre tolérance après les tests de faisabilité?
4. Quelles preuves minimales doivent être exigées avant une fermeture automatique?
5. Quelle règle appliquer si le GPS est indisponible au pointage d'entrée sur un chantier extérieur?
6. Les employés doivent-ils pointer une sortie et une nouvelle entrée pour le dîner ou les pauses?
7. Faut-il déduire automatiquement certaines pauses, ou attendre une règle confirmée?
8. Les totaux mensuels doivent-ils être calculés automatiquement à partir des sessions complètes validées, ou approuvés formellement par l'administrateur avant utilisation?
9. Pendant combien de temps faut-il conserver les résumés mensuels d'assiduité?
10. Que doit faire l'application si l'employé ne répond pas à la notification après 8 heures?
11. Quelle est la durée maximale absolue de surveillance autorisée pour une session anormalement longue?
12. Quelle procédure appliquer si la localisation est désactivée, si la permission est révoquée, si le téléphone est éteint ou si la connexion est perdue?
13. Quelles attentes souhaitez-vous communiquer aux employés qui utilisent leur téléphone personnel: permissions de localisation pour les chantiers extérieurs, batterie, notifications, refus de permission, téléphone éteint ou localisation désactivée?
14. Pendant combien de temps faut-il conserver séparément les données de localisation brutes, les sessions de travail, les résumés mensuels, les demandes de correction, les décisions administratives, les journaux d'audit et les sauvegardes?
15. Les décisions administratives liées à des employés identifiables peuvent-elles être conservées plus longtemps que les données GPS brutes, et selon quelle politique approuvée?
16. Quels champs doivent apparaître dans l'export CSV mensuel?
